// 验收：用研究目录里的测试图跑 `shizi-mcp ocr --json`（自动模式），跟研究时每张图「最好的那种认法」比。
// 用法：node bench/bench.mjs <研究目录> [--label 名字] [--only 正则]
// 研究目录要有 cases.json、summary.json、img/。插件按平常的配置文件走（SHIZI_CONFIG 可指定）。
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const HERE = path.dirname(new URL(import.meta.url).pathname);
const BIN = process.env.OCR_BIN ?? path.join(HERE, "..", ".build", "release", "shizi-mcp");
const args = process.argv.slice(2);
const testbed = args[0];
if (!testbed) {
	console.error("用法：node bench/bench.mjs <研究目录> [--label 名字] [--only 正则]");
	process.exit(2);
}
const flag = (name) => {
	const i = args.indexOf(name);
	return i >= 0 ? args[i + 1] : undefined;
};
const label = flag("--label") ?? "auto";
const only = flag("--only") ? new RegExp(flag("--only")) : null;

const cases = JSON.parse(fs.readFileSync(path.join(testbed, "cases.json"), "utf8"));
const research = JSON.parse(fs.readFileSync(path.join(testbed, "summary.json"), "utf8"));

// 研究里「事先知道答案才用得上」的认法不算进最好成绩：已知区域、已知圆心、已知角度、指定语言、自定义词。
const ORACLE = /^(roi|crop|polar|docrot:|lang:|custom:|enCustom)/;
const LAYOUT = new Set(["版面"]);

const norm = (s) => s.normalize("NFKC").replace(/\s+/g, "");
const core = (s) => [...norm(s)].filter((ch) => /[\p{L}\p{N}]/u.test(ch)).join("").toLowerCase();
function lev(a, b) {
	const A = [...a], B = [...b];
	if (!A.length) return B.length;
	if (!B.length) return A.length;
	let prev = new Uint32Array(B.length + 1), cur = new Uint32Array(B.length + 1);
	for (let j = 0; j <= B.length; j++) prev[j] = j;
	for (let i = 1; i <= A.length; i++) {
		cur[0] = i;
		for (let j = 1; j <= B.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (A[i - 1] === B[j - 1] ? 0 : 1));
		[prev, cur] = [cur, prev];
	}
	return prev[B.length];
}
const ord = (gt, out) => Math.max(0, 1 - lev(core(gt), core(out)) / Math.max(1, [...core(gt)].length));
function bag(gt, out) {
	const count = (s) => { const m = new Map(); for (const ch of s) m.set(ch, (m.get(ch) || 0) + 1); return m; };
	const g = count([...core(gt)]), o = count([...core(out)]);
	let inter = 0;
	for (const [ch, k] of g) inter += Math.min(k, o.get(ch) || 0);
	const gl = [...core(gt)].length, ol = [...core(out)].length;
	const rec = gl ? inter / gl : 1, prec = ol ? inter / ol : 0;
	return rec + prec ? (2 * rec * prec) / (rec + prec) : 0;
}
function tableCells(c, page) {
	const t = page.tables?.[0];
	if (!t || !c.table) return null;
	let ok = 0, total = 0;
	for (let i = 0; i < c.table.length; i++) for (let j = 0; j < c.table[i].length; j++) {
		total++;
		if (norm(t.rows[i]?.[j] ?? "") === norm(c.table[i][j])) ok++;
	}
	return { ok, total };
}

const rows = [];
const jobs = cases.filter((c) => !only || only.test(c.id));
async function worker() {
	while (jobs.length) {
		const c = jobs.shift();
		const t0 = Date.now();
		let page, error;
		try {
			const { stdout } = await run(BIN, ["ocr", path.join(testbed, c.img), "--json"], { maxBuffer: 64 << 20, timeout: 300000 });
			page = JSON.parse(stdout).pages[0];
		} catch (e) {
			error = String(e.stderr || e.message).slice(0, 200);
		}
		const wall = Date.now() - t0;
		// 分栏时每段开头的位置标记（〔中间〕之类）不是认出来的字，不算进分数。
		const text = page ? [page.text.replace(/^〔[^〕\n]+〕$/gm, ""), ...(page.barcodes ?? [])].join("\n") : "";
		// 只看字认没认对的一组用 bag；版面组再看顺序。
		const metric = LAYOUT.has(c.group) ? "ord" : "bag";
		// 条码组只看二维码内容认出来没有（标准答案里只有二维码内容，页面上的其它字不该算多余）。
		const score = c.group === "条码" ? Number((page?.barcodes ?? []).includes(c.gt)) : metric === "ord" ? ord(c.gt, text) : bag(c.gt, text);
		const best = research
			.filter((r) => r.id === c.id && !ORACLE.test(r.mode))
			.reduce((b, r) => (r[metric] > (b?.[metric] ?? -1) ? r : b), null);
		rows.push({
			id: c.id, group: c.group, desc: c.desc, metric, score, best: best?.[metric] ?? null, bestMode: best?.mode ?? null,
			mode: page?.mode, steps: page?.steps, table: page ? tableCells(c, page) : null, wall, error,
			suspects: page ? page.lines.filter((l) => l.suspect).length : 0,
		});
	}
}
await Promise.all([worker(), worker()]);
rows.sort((a, b) => cases.findIndex((c) => c.id === a.id) - cases.findIndex((c) => c.id === b.id));

const OUT = path.join(HERE, "out");
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, `${label}.json`), JSON.stringify(rows, null, 1));

const pct = (v) => (v == null ? "  -" : String(Math.round(v * 100)).padStart(3));
let worse = 0, better = 0;
for (const r of rows) {
	const diff = r.best == null ? 0 : r.score - r.best;
	if (diff < -0.02) worse++;
	if (diff > 0.02) better++;
	const flagText = diff < -0.02 ? "  ← 比最好的低" : diff > 0.02 ? "  ↑ 比最好的高" : "";
	const st = r.steps ? [r.mode, r.steps.tiles && `切块${r.steps.tiles}`, r.steps.rectified && "拉正", r.steps.upscaled && "放大"].filter(Boolean).join(" ") : "";
	console.log(
		`${r.id.padEnd(12)} ${r.metric} ${pct(r.score)}（最好 ${pct(r.best)} ${String(r.bestMode ?? "").slice(0, 10).padEnd(10)}） ${String(r.wall).padStart(5)}ms  ${st}${r.table ? ` 表${r.table.ok}/${r.table.total}` : ""}${r.error ? " 出错 " + r.error : ""}${flagText}`,
	);
}
const avg = (k) => rows.reduce((s, r) => s + (r[k] ?? 0), 0) / rows.length;
const wall = rows.map((r) => r.wall).sort((a, b) => a - b);
console.log(`\n${rows.length} 张：平均 ${pct(avg("score"))}（研究最好的平均 ${pct(avg("best"))}）；比最好的低 2 分以上 ${worse} 张，高 2 分以上 ${better} 张；耗时中位 ${wall[wall.length >> 1]} ms、最慢 ${wall[wall.length - 1]} ms`);
