# test-runner — Laravel stack notes

Read by the `test-runner` agent when the project's stack profile is Laravel
(`artisan` at the root). They win over the agent's defaults.

## File and filter

Append them to the resolved command in artisan syntax:

```bash
<test-cmd> <test-file>
<test-cmd> --filter=<filter>
<test-cmd> <test-file> --filter=<filter>
```

## Sail

When the resolved command starts with `vendor/bin/sail` (or `./vendor/bin/sail`),
the suite only runs inside the container. Never run any of these on the host:

```bash
php artisan test
vendor/bin/phpunit
./vendor/bin/phpunit
vendor/bin/pest
composer test
npm test
```

If Sail is down (`Sail is not running.`), return exactly:

```text
ERROR: Sail is not running. Start it with './vendor/bin/sail up -d'
```
