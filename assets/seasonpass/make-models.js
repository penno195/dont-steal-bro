// Generates the five Season 1 wearables, and the community reward's
// Corvus Crest Pack, with Meshy's text-to-3D API.
// Run: node assets/seasonpass/make-models.js  (needs MESHY_API_KEY in env)
// Writes assets/seasonpass/models/<name>/{model.fbx,model.glb,texture.png,thumb.png,task.json}.
// Re-running skips any item whose folder already has model.fbx.

const fs = require("fs");
const path = require("path");

const KEY = process.env.MESHY_API_KEY;
if (!KEY) throw new Error("MESHY_API_KEY not set");
const API = "https://api.meshy.ai/openapi/v2/text-to-3d";
const OUT = path.join(__dirname, "models");

const STYLE =
	"stylised cartoon game asset, chunky smooth simple shapes, bold clean colours, Roblox accessory, exactly one object, no character, no stand, no pedestal, no display base";
const ITEMS = {
	LootSackBack: {
		prompt: `A bulging burlap swag bag tied at the top with rope, a dollar sign printed on the side, worn as a backpack. ${STYLE}`,
		texture: "tan burlap sack, dark brown rope, bold green dollar sign",
	},
	BurglarBeanieHat: {
		prompt: `A smooth rounded black beanie hat with a thick folded cuff, soft simple dome shape, hat only. ${STYLE}`,
		texture: "matte black fabric with a subtle knit pattern, thin grey stripe on the cuff",
	},
	TrafficConeHat: {
		prompt: `One single orange traffic cone with two white reflective stripes and a flat square black rubber base. ${STYLE}`,
		texture: "bright orange plastic, two white reflective stripes, black base",
	},
	GameShowTopHat: {
		prompt: `A classic magician top hat: a tall straight cylinder crown with a flat round top, and one single flat brim only at the very bottom. Gold sequinned, red ribbon band just above the brim. ${STYLE}`,
		texture: "entirely metallic gold sequinned surface, gold brim, glossy red ribbon band",
	},
	GoldBarJetpack: {
		prompt: `A backpack jetpack made of a stack of shiny gold ingot bars (trapezoid gold bullion bricks) strapped together with black belts, two grey rocket nozzles underneath. ${STYLE}`,
		texture: "shiny yellow gold bullion bars, dark grey metal rocket nozzles, black belts",
	},
	CorvusCrestPack: {
		prompt: `A sleek luxury hard-shell backpack, glossy black with polished gold trim along its edges, a large gold raven emblem with spread wings on the front, two short gold straps. ${STYLE}`,
		texture: "glossy jet black lacquer shell, polished gold trim, gold raven crest emblem with spread wings, deep purple accents",
	},
};

const headers = { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function create(body) {
	const res = await fetch(API, { method: "POST", headers, body: JSON.stringify(body) });
	const text = await res.text();
	if (!res.ok) throw new Error(`create ${res.status}: ${text}`);
	return JSON.parse(text).result;
}

async function wait(id, name, stage) {
	for (;;) {
		let task;
		try {
			task = await (await fetch(`${API}/${id}`, { headers })).json();
		} catch (e) {
			console.log(`${name} ${stage} poll failed (${e.message}), retrying`);
			await sleep(15000);
			continue;
		}
		if (task.status === "SUCCEEDED") return task;
		if (task.status === "FAILED" || task.status === "CANCELED")
			throw new Error(`${name} ${stage} ${task.status}: ${JSON.stringify(task.task_error)}`);
		console.log(`${name} ${stage} ${task.status} ${task.progress}%`);
		await sleep(15000);
	}
}

async function download(url, file) {
	const res = await fetch(url);
	if (!res.ok) throw new Error(`download ${res.status} ${url}`);
	fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()));
}

async function make(name, item) {
	const dir = path.join(OUT, name);
	if (fs.existsSync(path.join(dir, "model.fbx"))) return console.log(`${name} exists, skipped`);
	fs.mkdirSync(dir, { recursive: true });
	// resume.json {previewId?, refineId?} picks up tasks a crashed run left at Meshy.
	const resumeFile = path.join(dir, "resume.json");
	const resume = fs.existsSync(resumeFile) ? JSON.parse(fs.readFileSync(resumeFile, "utf8")) : {};
	const previewId = resume.previewId ?? resume.refineId ?? await create({
		mode: "preview",
		prompt: item.prompt,
		ai_model: "latest",
		should_remesh: true,
		topology: "triangle",
		target_polycount: 4000, // mobile-first: a cheap accessory, well under Roblox's 20k cap
		target_formats: ["glb", "fbx"],
	});
	if (!resume.refineId) await wait(previewId, name, "preview");
	const refineId = resume.refineId ?? await create({
		mode: "refine",
		preview_task_id: previewId,
		texture_prompt: item.texture,
		texture_resolution: "2k",
		target_formats: ["glb", "fbx"],
	});
	const task = await wait(refineId, name, "refine");
	fs.writeFileSync(path.join(dir, "task.json"), JSON.stringify(task, null, 2));
	await download(task.model_urls.fbx, path.join(dir, "model.fbx"));
	await download(task.model_urls.glb, path.join(dir, "model.glb"));
	await download(task.texture_urls[0].base_color, path.join(dir, "texture.png"));
	if (task.thumbnail_url) await download(task.thumbnail_url, path.join(dir, "thumb.png"));
	console.log(`${name} DONE (${task.consumed_credits ?? "?"} credits)`);
}

(async () => {
	const results = await Promise.allSettled(Object.entries(ITEMS).map(([n, i]) => make(n, i)));
	results.forEach((r, i) => r.status === "rejected" && console.error(Object.keys(ITEMS)[i], r.reason.message));
	process.exitCode = results.some((r) => r.status === "rejected") ? 1 : 0;
})();
