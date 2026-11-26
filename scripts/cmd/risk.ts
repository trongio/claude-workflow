#!/usr/bin/env bun
// wf-help: risk level of the current change set: high|standard|light <deciding file>
import { baseBranch, changedFiles, classifyRisk, git, parseArgs } from '../lib.ts';

const HELP = `Usage: wf risk [BASE] [--json]

Classifies the files changed since BASE (default: the base branch), committed or
not: any path in risk.high -> high; only *.md, docs/, tests/ or *.css -> light;
anything else -> standard. Prints "<level> <deciding file>".`;

const { flags, args } = parseArgs(process.argv.slice(2), { json: 'bool' }, HELP);
const base = args[0] ?? baseBranch();
const here = git(['rev-parse', '--show-toplevel'], process.cwd()).out;
const files = changedFiles(base, 'HEAD', here);
const risk = classifyRisk(files);
if (flags.json) console.log(JSON.stringify({ ...risk, base, files: files.length }));
else console.log(`${risk.level} ${risk.file}`);
