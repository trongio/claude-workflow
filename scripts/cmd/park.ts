#!/usr/bin/env bun
// wf-help: park a card on an owner decision (owner-review + blocked + a note)
import { appendToSection, findCard, parseArgs, readCards, today, update, withLock } from '../lib.ts';

const HELP = `Usage: wf park ID "owner: question"

Moves the card to owner-review, sets blocked to the question (prefixed "owner: "
when missing) and records it in ## Notes. Unpark with wf move ID <status> --blocked "".`;

const { args } = parseArgs(process.argv.slice(2), {}, HELP);
const [id, question] = args;
if (!id || !question) {
    console.error(HELP);
    process.exit(2);
}
const blocked = /^owner:/i.test(question) ? question : `owner: ${question}`;
withLock(() => {
    const card = findCard(readCards(), id);
    update(card, { status: 'owner-review', blocked }, (t) => appendToSection(t, 'Notes', `- ${today()} parked: ${blocked}`));
    console.log(`${card.id} ${card.status} -> owner-review  [${blocked}]`);
});
