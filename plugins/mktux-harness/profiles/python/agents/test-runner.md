# test-runner — Python stack notes

Read by the `test-runner` agent when the project's stack profile is Python
(`pyproject.toml` at the root). They win over the agent's defaults.

## File and filter

Append paths and filters in pytest syntax:

```bash
<test-cmd> <test-file>
<test-cmd> -k "<filter>"
<test-cmd> <test-file> -k "<filter>"
```

Keep the resolved environment wrapper. Never replace `uv run pytest` or
`poetry run pytest` with host `pytest`, `python -m pytest`, or another installer.

If the uv environment lacks the development extra, return exactly:

```text
ERROR: pytest is not installed in the uv environment. Run 'uv sync --extra dev'
```
