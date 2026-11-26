#!/usr/bin/env bun
// wf-help: append a dated line to a card's ## Notes
import { appendToSection, findCard, parseArgs, readCards, today, update, withLock } from '../lib.ts';

const HELP = `Usage: wf note ID "text"

Appends "- <date> text" to the card's ## Notes section (created when missing).`;

const { args } = parseArgs(process.argv.slice(2), {}, HELP);
const [id, text] = args;
if (!id || !text) {
    console.error(HELP);
    process.exit(2);
}
withLock(() => {
    const card = findCard(readCards(), id);
    update(card, {}, (t) => appendToSection(t, 'Notes', `- ${today()} ${text}`));
    console.log(`${card.id} note added`);
});
