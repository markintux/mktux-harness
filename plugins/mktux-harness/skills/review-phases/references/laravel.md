# Perfil Laravel — review phases

Carregado pela skill `review-phases` quando existe `artisan` na raiz do
projeto, e lido pelo agent `security-auditor` quando ele roda num projeto
Laravel. Fonte unica do que a auditoria de seguranca tem de Laravel: o Codex
nao tem o agent e audita com esta secao direto.

## Arquivos relevantes a seguranca web (secao 4)

Tipicamente sob:

```text
routes/
app/Http/
app/Actions/
app/Services/
app/Models/
app/Policies/
app/Enums/
resources/views/
database/migrations/
```

## Security audit — Laravel

Stack: a Laravel monolith using Breeze, Blade, FormRequests, Actions,
Policies/Middleware, Sail, and PHPUnit.

### Process

1. Run `./vendor/bin/sail artisan route:list --except-vendor` to list application routes.
2. Inspect relevant web route files, usually `routes/web.php` and any custom web route files like `routes/admin.php` or any other project-specific web route file if they exist.
3. For each relevant web flow, open the Controller, FormRequest, Action, Policy/Middleware, Model, and Blade form when applicable.

### Checklist (on top of the generic one)

- [ ] Protected routes use the correct middleware, such as `auth`, `verified`, admin middleware, or another project-specific middleware.
- [ ] Authorization is enforced with Policy, Gate, Middleware, or explicit authorization logic.
- [ ] Non-trivial form submissions use a dedicated FormRequest.
- [ ] Controllers do not use `$request->all()` for create/update/mass assignment.
- [ ] Only validated data is passed to Actions, Services, or Models.
- [ ] Models have correct `$fillable` protection for mass-assignable attributes.
- [ ] Enum-backed fields use Enum values instead of unsafe raw strings.
- [ ] Blade forms that mutate state include CSRF protection.
- [ ] Actions do not directly depend on `request()`, `session()`, or `auth()` for security-sensitive decisions. Required values should be passed as parameters.

### Example report

```md
**OK**

- GET /dashboard — dashboard
- POST /profile — profile.update

**ATTENTION**

1. `POST /admin/plans` — `admin.plans.store`
   - issue: Controller uses `$request->all()` for mass assignment.
   - location: `app/Http/Controllers/Admin/Plan/StorePlanController.php:27`
   - impact: Unexpected request fields may be persisted.
   - recommendation: Use a dedicated FormRequest and pass only validated data.

2. `GET /account/orders/{order}` — `account.orders.show`
   - issue: Ownership is not enforced before showing the record.
   - location: `app/Http/Controllers/Account/Order/ShowOrderController.php:19`
   - impact: A user may access another user's order by changing the ID.
   - recommendation: Enforce a Policy/Gate or query through the authenticated user's relationship.
```
