#!/usr/bin/env bun
// wf-help: risk level of the current change set: high|standard|light <deciding file>; --explain lists the rules
import { LIGHT_GLOBS, baseBranch, changedFiles, classifyRisk, git, highGlobs, parseArgs } from '../lib.ts';

const HELP = `Usage: wf risk [BASE] [--json] [--explain]

Classifies the files changed since BASE (default: the base branch), committed or
not: any path matching a high pattern -> high; only *.md, docs/, tests/ or *.css
-> light; anything else -> standard. Prints "<level> <deciding file>".
High patterns are risk.high from .claude/workflow.json when it is set (it replaces
the built-in list; [] turns high risk off), else a built-in list: migrations,
*.sql and schema files, auth, billing and payments, security, infra/, deploy/,
.github/workflows/, Dockerfiles. --explain prints the patterns in force.
Patterns: * matches across directories, ? one character, a trailing / everything under it.`;

const { flags, args } = parseArgs(process.argv.slice(2), { json: 'bool', explain: 'bool' }, HELP);
if (flags.explain) {
    const { globs, source } = highGlobs();
    if (flags.json) console.log(JSON.stringify({ high: globs, source, light: LIGHT_GLOBS }));
    else {
        console.log(`high (${source === 'config' ? 'risk.high in .claude/workflow.json' : 'built-in; set risk.high to replace'}): ${globs.join(' ') || '(none: high risk is off)'}`);
        console.log(`light (only these changed): ${LIGHT_GLOBS.join(' ')}`);
        console.log('standard: anything else');
    }
    process.exit(0);
}
const base = args[0] ?? baseBranch();
const here = git(['rev-parse', '--show-toplevel'], process.cwd()).out;
const files = changedFiles(base, 'HEAD', here);
const risk = classifyRisk(files);
if (flags.json) console.log(JSON.stringify({ ...risk, base, files: files.length }));
else console.log(`${risk.level} ${risk.file}`);
