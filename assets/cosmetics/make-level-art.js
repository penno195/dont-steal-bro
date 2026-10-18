// Generates the source art for the three level-reward cosmetics
// (Climber's Trail, Veteran Frame, Old Hand flair) with Meshy's
// text-to-image API. make-level-art.py then cuts these into the game
// textures and Locker pictures.
// Run: node assets/cosmetics/make-level-art.js  (needs MESHY_API_KEY in env)
// Writes assets/cosmetics/meshy/<name>.png. Re-running skips any image
// that already exists, so delete one to redraw it.

const fs = require("fs");
const path = require("path");

const KEY = process.env.MESHY_API_KEY;
if (!KEY) throw new Error("MESHY_API_KEY not set");
const API = "https://api.meshy.ai/openapi/v1/text-to-image";
const OUT = path.join(__dirname, "meshy");

const STYLE =
	"bold clean cartoon game icon, thick dark outline, flat cel shading, centred, single object, no text, no letters, plain background";
const ITEMS = {
	// Old Hand flair: two laurel sprigs framing the streak counter.
	"old-hand-laurel": {
		prompt: `A single curved laurel branch with glossy leaves, purple and lilac leaves with gold highlights, branch lying horizontally. ${STYLE}`,
		aspect: "16:9",
	},
	// Locker pictures, one per item.
	"pic-climber-trail": {
		prompt: `A chunky solid mountain with opaque grey-blue rock and bright white snow caps, a thick glowing cyan zig-zag path climbing up its face to a red flag on the summit, everything fully opaque. ${STYLE}`,
		aspect: "1:1",
	},
	"pic-veteran-frame": {
		prompt: `A steel-grey military medal badge with three silver chevron stripes on a shield shape. ${STYLE}`,
		aspect: "1:1",
	},
	"pic-old-hand": {
		prompt: `A purple laurel wreath circling a big solid bright magenta and violet flame with a white-hot core, the flame fully opaque and bright. ${STYLE}`,
		aspect: "1:1",
	},
};

async function call(method, url, body) {
	const res = await fetch(url, {
		method,
		headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
		body: body ? JSON.stringify(body) : undefined,
	});
	if (!res.ok) throw new Error(`${method} ${url}: ${res.status} ${await res.text()}`);
	return res.json();
}

async function make(name, item) {
	const file = path.join(OUT, `${name}.png`);
	if (fs.existsSync(file)) return console.log(`skip ${name}`);
	const { result: id } = await call("POST", API, {
		ai_model: "nano-banana",
		prompt: item.prompt,
		aspect_ratio: item.aspect,
		remove_background: true,
	});
	for (;;) {
		await new Promise((r) => setTimeout(r, 4000));
		const task = await call("GET", `${API}/${id}`);
		if (task.status === "SUCCEEDED") {
			const img = await fetch(task.image_urls[0]);
			fs.writeFileSync(file, Buffer.from(await img.arrayBuffer()));
			return console.log(`wrote ${name}`);
		}
		if (task.status === "FAILED" || task.status === "CANCELED")
			throw new Error(`${name}: ${task.status} ${JSON.stringify(task.task_error)}`);
	}
}

(async () => {
	fs.mkdirSync(OUT, { recursive: true });
	await Promise.all(Object.entries(ITEMS).map(([name, item]) => make(name, item)));
})();
