#!/usr/bin/env node
// Runs RustDedicated, shows its output until WebRCON is up, then switches the
// panel console to WebRCON. Based on the pterodactyl/yolks games/rust wrapper (MIT).

const fs = require("fs");
const { exec } = require("child_process");

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

function filter(data) {
	const str = data.toString();
	if (noise.some((n) => str.includes(n))) return;

	// Rust repeats the same percentage many times, so drop duplicates.
	if (str.startsWith("Loading Prefab Bundle ")) {
		const percentage = str.substr("Loading Prefab Bundle ".length);
		if (seenPercentage[percentage]) return;
		seenPercentage[percentage] = true;
	}

	process.stdout.write(str.endsWith("\n") ? str : str + "\n");
}

console.log("Starting Rust...");

let exited = false;
const gameProcess = exec(startupCmd, { maxBuffer: 1024 * 1024 * 64 });
gameProcess.stdout.on("data", filter);
gameProcess.stderr.on("data", filter);
gameProcess.on("exit", function (code) {
	exited = true;
	if (code) {
		console.log("Main game process exited with code " + code);
	}
	process.exit(code || 0);
});

function initialListener(data) {
	const command = data.toString().trim();
	if (command === "quit") {
		gameProcess.kill("SIGTERM");
	} else {
		console.log('Unable to run "' + command + '" because RCON is not connected yet.');
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

function poll() {
	function createPacket(command) {
		return JSON.stringify({ Identifier: -1, Message: command, Name: "WebRcon" });
	}

	const serverHostname = process.env.RCON_IP ? process.env.RCON_IP : "localhost";
	const serverPort = process.env.RCON_PORT;
	const serverPassword = process.env.RCON_PASS;
	const WebSocket = require("ws");
	const ws = new WebSocket("ws://" + serverHostname + ":" + serverPort + "/" + serverPassword);

	ws.on("open", function open() {
		console.log('Connected to RCON. Generating the map now. Please wait until the server status switches to "Running".');
		waiting = false;

		// Ask for status once so the console shows output straight away.
		ws.send(createPacket("status"));

		process.stdin.removeListener("data", initialListener);
		gameProcess.stdout.removeListener("data", filter);
		gameProcess.stderr.removeListener("data", filter);
		process.stdin.on("data", function (text) {
			ws.send(createPacket(text));
		});
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
			console.log(e);
		}
	});

	ws.on("error", function () {
		waiting = true;
		console.log("Waiting for RCON to come up...");
		setTimeout(poll, 5000);
	});

	ws.on("close", function () {
		if (!waiting) {
			console.log("Connection to server closed.");
			exited = true;
			process.exit();
		}
	});
}

poll();
