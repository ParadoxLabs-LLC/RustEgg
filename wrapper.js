#!/usr/bin/env node
// Runs RustDedicated, shows its output until WebRCON is up, then switches the
// panel console to WebRCON. Based on the pterodactyl/yolks games/rust wrapper (MIT).

const fs = require("fs");
const os = require("os");
const { spawn } = require("child_process");

let WebSocket;
try {
	WebSocket = require("ws");
} catch (e) {
	WebSocket = require("/opt/wrapper/node_modules/ws");
}

const startupCmd = process.argv.slice(2).join(" ");
if (startupCmd.length < 1) {
	console.log("Error: Please specify a startup command.");
	process.exit(1);
}

fs.writeFile("latest.log", "", (err) => {
	if (err) console.log("Callback error in writeFile: " + err);
});

// Harmless Unity/server noise that floods the console during boot.
const noise = [
	"Fallback handler could not load library",
	"Filename:",
	"ERROR: Shader ",
	"WARNING: Shader ",
	"The referenced script ",
	"Hidden/PostProcessing/",
	"Sprites/Multiply",
	"Couldn't create a Convex Mesh",
	"HDR Render Texture not supported",
	"RuntimeNavMeshBuilder: ",
];

const seenPercentage = {};

// Filters line by line, so one noisy line never hides real errors in the same chunk.
function filter(data) {
	const kept = [];
	for (const line of data.toString().split("\n")) {
		if (line.length === 0) continue;
		if (noise.some((n) => line.includes(n))) continue;

		// Rust repeats the same percentage many times, so drop duplicates.
		if (line.startsWith("Loading Prefab Bundle ")) {
			const percentage = line.substr("Loading Prefab Bundle ".length);
			if (seenPercentage[percentage]) continue;
			seenPercentage[percentage] = true;
		}
		kept.push(line);
	}
	if (kept.length) process.stdout.write(kept.join("\n") + "\n");
}

console.log("Starting Rust...");

let exited = false;
// spawn streams output. exec() buffers it all and kills the game once maxBuffer fills.
// bash, so Carbon's environment.sh can be sourced in the startup line.
const gameProcess = spawn(startupCmd, { shell: fs.existsSync("/bin/bash") ? "/bin/bash" : true });
gameProcess.stdout.on("data", filter);
gameProcess.stderr.on("data", filter);

// The container stops only when the game itself stops, never on an RCON drop.
gameProcess.on("exit", function (code, signal) {
	exited = true;
	if (code) {
		console.log("Main game process exited with code " + code);
	}
	if (signal) {
		console.log("Main game process killed with signal " + signal);
	}
	// A signal kill (for example out of memory) must not look like a clean exit.
	process.exit(code !== null ? code : signal ? 128 + (os.constants.signals[signal] || 0) : 0);
});

function initialListener(data) {
	const command = data.toString().trim();
	if (command === "quit") {
		gameProcess.kill("SIGTERM");
	} else {
		console.log('Unable to run "' + command + '" because RCON is not connected yet.');
	}
}

function rconListener(text) {
	if (ws && ws.readyState === WebSocket.OPEN) {
		ws.send(createPacket(text));
	} else if (text.trim() === "quit") {
		gameProcess.kill("SIGTERM");
	} else {
		console.log("Cannot send command: RCON is reconnecting.");
	}
}

process.stdin.resume();
process.stdin.setEncoding("utf8");
process.stdin.on("data", initialListener);

process.on("exit", function () {
	if (exited) return;
	console.log("Received request to stop the process, stopping the game...");
	gameProcess.kill("SIGTERM");
});

let waiting = true;
let ws = null;
let onRcon = false;

function createPacket(command) {
	return JSON.stringify({ Identifier: -1, Message: command, Name: "WebRcon" });
}

// Switch console input/output between the game's own output and WebRCON.
function useRcon(enable) {
	if (enable === onRcon) return;
	onRcon = enable;
	if (enable) {
		process.stdin.removeListener("data", initialListener);
		process.stdin.on("data", rconListener);
		gameProcess.stdout.removeListener("data", filter);
		gameProcess.stderr.removeListener("data", filter);
		// Keep draining game output so a full pipe never blocks the game.
		gameProcess.stdout.resume();
		gameProcess.stderr.resume();
	} else {
		process.stdin.removeListener("data", rconListener);
		process.stdin.on("data", initialListener);
		gameProcess.stdout.on("data", filter);
		gameProcess.stderr.on("data", filter);
	}
}

function poll() {
	if (exited) return;
	const serverHostname = process.env.RCON_IP ? process.env.RCON_IP : "127.0.0.1";
	const serverPort = process.env.RCON_PORT;
	const serverPassword = process.env.RCON_PASS;
	ws = new WebSocket("ws://" + serverHostname + ":" + serverPort + "/" + serverPassword);

	ws.on("open", function open() {
		console.log('Connected to RCON. Generating the map now. Please wait until the server status switches to "Running".');
		waiting = false;
		// Ask for status once so the console shows output straight away.
		ws.send(createPacket("status"));
		useRcon(true);
	});

	ws.on("message", function (data) {
		try {
			const json = JSON.parse(data);
			if (json && json.Message !== undefined && json.Message.length > 0) {
				console.log(json.Message);
				fs.appendFile("latest.log", "\n" + json.Message, (err) => {
					if (err) console.log("Callback error in appendFile: " + err);
				});
			}
		} catch (e) {
			console.log("Error parsing RCON message: " + e.message);
		}
	});

	ws.on("error", function () {
		waiting = true;
		console.log("Waiting for RCON to come up...");
		setTimeout(poll, 5000);
	});

	// An RCON drop used to exit the wrapper, which killed the game without a save. Reconnect instead.
	ws.on("close", function () {
		if (!waiting) {
			waiting = true;
			useRcon(false);
			console.log("RCON connection closed. Reconnecting...");
			setTimeout(poll, 5000);
		}
	});
}

// Wings sends SIGTERM when a stop times out. Node is PID 1 and ignores it by default,
// so ask Rust to save and quit, falling back to a plain SIGTERM.
process.on("SIGTERM", function () {
	if (ws && ws.readyState === WebSocket.OPEN) {
		ws.send(createPacket("quit"));
	} else {
		gameProcess.kill("SIGTERM");
	}
});

poll();
