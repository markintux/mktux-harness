# test-runner — Node.js stack notes

Read by the `test-runner` agent when the project's stack profile is Node.js
(`package.json` at the root). They win over the agent's defaults.

## File and filter

When the resolved command is a test script, pass runner arguments after npm's
`--` separator:

```bash
<test-cmd> -- <test-file>
<test-cmd> -- -t "<filter>"
<test-cmd> -- <test-file> -t "<filter>"
```

When the resolved command is `npm run check`, it is the project's indivisible
mechanical gate. Run it exactly as resolved; do not append a file or filter.

Never replace an npm script with `npx`, a direct `node_modules/.bin` path, or a
globally installed runner.
