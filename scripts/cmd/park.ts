#!/usr/bin/env bun
// wf-help: park a card on an owner decision (owner-review + blocked + a note)
import { appendToSection, findCard, parkFields, parseArgs, readCards, today, update, withLock } from '../lib.ts';

const HELP = `Usage: wf park ID "owner: question"

Moves the card to owner-review, sets blocked to the question (prefixed "owner: "
when missing) and records it in ## Notes. The owner answers with wf approve ID,
which clears blocked and puts the card back where it was.

Example: wf park T-4 "owner: ship the CSV export now or with the PDF one?"`;

const { args } = parseArgs(process.argv.slice(2), {}, HELP);
const [id, question] = args;
if (!id || !question) {
    console.error(HELP);
    process.exit(2);
}
const blocked = /^owner:/i.test(question) ? question : `owner: ${question}`;
withLock(() => {
    const card = findCard(readCards(), id);
    update(card, parkFields(card, blocked), (t) => appendToSection(t, 'Notes', `- ${today()} parked: ${blocked}`));
    console.log(`${card.id} ${card.status} -> owner-review  [${blocked}]`);
});
