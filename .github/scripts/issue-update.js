// Tells the person behind an issue where it stands, as arctim-janitor. Run by .github/workflows/issue-update.yml; test
// with `node --test .github/scripts/`. Most reports come through the report relay, whose sender has no GitHub account
// and can't reply here, so a comment points back to OverPass.

const OUTCOMES = {
  verified: 'Fixed: the problem was reproduced, and the fix was tested against it.',
  untested: "This should work now, but the fix hasn't been tested against the problem itself, so it may need a try on your side.",
};
const AGAIN = 'If it still happens, send a new report from OverPass.';

function comment({ problem, outcome, release }) {
  if (!Object.hasOwn(OUTCOMES, outcome)) throw new Error(`Unknown outcome: ${outcome}`);
  const text = (problem || '').trim();
  if (!text) throw new Error('The comment needs a description of the problem.');
  const when = release?.trim() ? `It's in OverPass ${release.trim()}.` : 'It comes with the next OverPass update.';
  return `${text}\n\n${OUTCOMES[outcome]} ${when} ${AGAIN}`;
}

/// The workflow's step.
async function run({ github, context, inputs }) {
  await github.rest.issues.createComment({ ...context.repo, issue_number: Number(inputs.issue), body: comment(inputs) });
}

module.exports = { comment, run };
