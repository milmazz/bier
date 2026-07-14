# Authentication

The [Getting Started](getting-started.md) tutorial served the brewery
catalog to anyone — every request ran as the anonymous `web_anon` role and
could only read. This tutorial adds the other half: letting an
*authenticated* client do something the anonymous one cannot. Concretely, a
brewery member will post a check-in — a write `web_anon` is not allowed to
make.

Bier follows PostgREST's model exactly. There are no sessions, no login
endpoint, and no user table Bier knows about. A client proves who it is by
sending a **JSON Web Token (JWT)** signed with a secret the server also
holds; Bier verifies the signature, reads the `role` claim, and runs that
request's SQL under `SET LOCAL ROLE <role>`. Authorization is then plain
PostgreSQL `GRANT`s — the database, not Bier, decides what each role may do.

This tutorial assumes you have already loaded `docs/tutorials/brewery.sql`
and can run Bier against it, exactly as Getting Started describes.

## The role split is already in the schema

`brewery.sql` created three roles on purpose (re-read its comments if you
skipped them):

* **`authenticator`** — the role Bier connects to Postgres as. It has
  `noinherit login` and *no table privileges of its own*; it can only
  switch into one of the roles below for the duration of a request.
* **`web_anon`** — the anonymous role. It can `select` every table but
  cannot write.
* **`brewery_member`** — additionally granted `insert` on `api.check_ins`
  (and `usage` on its id sequence).

The relevant grants:

```sql
grant select on api.styles, api.breweries, api.beers, api.taprooms, api.check_ins to web_anon;

grant select on api.styles, api.breweries, api.beers, api.taprooms, api.check_ins to brewery_member;
grant insert on api.check_ins to brewery_member;
grant usage on sequence api.check_ins_id_seq to brewery_member;
```

So the difference between "can post a check-in" and "cannot" is entirely a
matter of *which role the request runs as*, and that is decided by the token.

### Anonymous writes are denied

Boot Bier the same way as before, but connecting as the real
`authenticator` role (not your superuser account — a superuser owns the
tables and would bypass the very privilege checks this tutorial is about).
Everything in this tutorial assumes Bier is reachable at
`http://localhost:4040`.

```sh
iex -S mix run -e 'Bier.start_link(
  name: Tutorial,
  router: [port: 4040, scheme: :http],
  database: "bier_tutorial",
  username: "authenticator",
  password: "mysecretpassword",
  db_schemas: ["api"],
  db_anon_role: "web_anon"
)'
```

Now try to post a check-in with no token:

```bash
curl -i "http://localhost:4040/check_ins" \
  -H "Content-Type: application/json" \
  -d '{"beer_id":1,"drinker":"sam","rating":5,"comment":"great"}'
```

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Content-Type: application/json; charset=utf-8
```

```json
{"code":"42501","details":null,"hint":null,"message":"permission denied for table check_ins"}
```

The request ran as `web_anon`, which has no `insert` on `api.check_ins`, so
PostgreSQL raised `42501` (insufficient privilege). Because the request was
anonymous, Bier surfaces that as **401 Unauthorized** with a
`WWW-Authenticate: Bearer` header — the HTTP way of saying "authenticate and
try again" — rather than a bare 403. That is exactly the behavior we want:
the door is locked, and it tells the client a key would help.

## Configure the JWT secret

To accept keys, Bier needs the secret it will verify signatures against. Add
`jwt_secret` to the boot options. Bier verifies HS256 (HMAC) tokens when the
secret is an ordinary string; the secret must be **at least 32 bytes** — a
shorter one is rejected at boot.

```sh
iex -S mix run -e 'Bier.start_link(
  name: Tutorial,
  router: [port: 4040, scheme: :http],
  database: "bier_tutorial",
  username: "authenticator",
  password: "mysecretpassword",
  db_schemas: ["api"],
  db_anon_role: "web_anon",
  jwt_secret: "the-tutorial-jwt-secret-change-me-please"
)'
```

Standalone, the same secret comes from an environment variable:

```sh
BIER_STANDALONE=1 \
PGRST_DB_URI="postgresql://authenticator:mysecretpassword@localhost:5432/bier_tutorial" \
PGRST_DB_SCHEMAS="api" \
PGRST_DB_ANON_ROLE="web_anon" \
PGRST_JWT_SECRET="the-tutorial-jwt-secret-change-me-please" \
_build/prod/rel/bier/bin/bier start
```

With a secret configured, role-switching now applies to every request on the
`api` schema: a request carrying a valid token runs as the token's `role`
claim, and a request without one still runs as `db_anon_role` (`web_anon`).
This is the same uniform model PostgREST uses — authentication is not opted
in per-table or per-schema; it applies to the whole exposed surface.

## Mint a token

A token for our purposes is a JWT with one claim, `role`, naming the
PostgreSQL role the request should assume:

```json
{"role": "brewery_member"}
```

It must be signed **HS256** with the same secret Bier is configured with.
Since `:jose` is already a dependency of this project, you can mint one in an
`iex` session without any extra tooling:

```elixir
secret = "the-tutorial-jwt-secret-change-me-please"
jwk = JOSE.JWK.from_oct(secret)

{_, token} =
  JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, %{"role" => "brewery_member"})
  |> JOSE.JWS.compact()

IO.puts(token)
```

That prints a token like:

```text
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYnJld2VyeV9tZW1iZXIifQ.UvAakyOakEKZK87bb3ljcEddeGulfjoJEDqN3zYxuSg
```

If you would rather not open a shell, [jwt.io](https://jwt.io) can build the
same token in the browser: choose the **HS256** algorithm, set the payload
to `{"role": "brewery_member"}`, and paste the secret into the
"verify signature" box. Copy the encoded token from the left panel.

> **Where `role` comes from.** Bier reads the role from the `role` claim by
> default. That path is the `jwt_role_claim_key` option (default `.role`);
> if your identity provider nests the role elsewhere — say
> `{"https://example.com/roles": ["brewery_member"]}` — you point Bier at it
> with `jwt_role_claim_key: ".\"https://example.com/roles\"[0]"`. See the
> [Configuration guide](../guides/configuration.md) for the full JSPath
> grammar.
>
> **Expiry.** Real tokens should carry an `exp` (expiration) claim — a Unix
> timestamp after which Bier rejects the token with `401` (`PGRST303`,
> "JWT expired"). The minimal token above has none, so it never expires,
> which is fine for a tutorial and wrong for anything else.

## Authenticated writes succeed

Send the same POST again, this time with the token in an
`Authorization: Bearer` header. `Prefer: return=representation` asks Bier to
return the inserted row:

```bash
TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYnJld2VyeV9tZW1iZXIifQ.UvAakyOakEKZK87bb3ljcEddeGulfjoJEDqN3zYxuSg"

curl -i "http://localhost:4040/check_ins" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"beer_id":1,"drinker":"sam","rating":5,"comment":"great"}'
```

```http
HTTP/1.1 201 Created
Content-Type: application/json; charset=utf-8
```

```json
[{"id":6,"beer_id":1,"drinker":"sam","rating":5,"comment":"great","created_at":"2026-07-14T09:00:31.050203+00:00"}]
```

The check-in was created. Nothing about the SQL changed — the only
difference from the denied request is the token, which made Bier run the
insert as `brewery_member` instead of `web_anon`. Drop the header and the
same request is still **401**, exactly as before.

### Reading the token's claims from SQL

Bier does more than switch the role: before running your query it also
publishes the token's full claims to the transaction, where SQL can read
them with `current_setting('request.jwt.claims', true)::json`. A tiny
function makes this visible over HTTP — add it to your database:

```sql
create function api.whoami() returns json
  language sql stable as $$
    select current_setting('request.jwt.claims', true)::json;
  $$;

grant execute on function api.whoami() to web_anon, brewery_member;
```

Then reload Bier's schema cache so it picks up the new function
(`notify pgrst, 'reload schema';` from `psql`, or restart the instance) and
call it. With the member token:

```bash
curl "http://localhost:4040/rpc/whoami" -H "Authorization: Bearer $TOKEN"
```

```json
{"role": "brewery_member"}
```

And with no token, the anonymous claims Bier synthesizes for `web_anon`:

```bash
curl "http://localhost:4040/rpc/whoami"
```

```json
{"role": "web_anon"}
```

This is the hook that makes row-level security practical: a policy or
function can read any claim the token carried — a tenant id, a user id, a
list of scopes — straight from `request.jwt.claims` and decide what the
current request may see or do.

## Optional: a pre-request guard

Sometimes role-based grants are not enough — you want a check that runs on
*every* request, before the main query, and can reject it outright. That is
the `db_pre_request` hook (PostgREST calls this the `check_token` pattern).
Bier runs the named function inside the same transaction, right after
establishing the role and claims; if it raises, the whole request is
aborted.

For example, to ban a specific drinker regardless of their token:

```sql
create function api.check_token() returns void
  language plpgsql stable as $$
  declare
    claims json := current_setting('request.jwt.claims', true)::json;
  begin
    if claims ->> 'drinker' = 'banned_bob' then
      raise insufficient_privilege
        using message = 'account suspended';
    end if;
  end;
  $$;
```

Wire it in with the `db_pre_request` option (or `PGRST_DB_PRE_REQUEST`
standalone):

```elixir
Bier.start_link(
  # ...the options from above...
  jwt_secret: "the-tutorial-jwt-secret-change-me-please",
  db_pre_request: "api.check_token"
)
```

Now any request whose token carries `"drinker": "banned_bob"` is rejected
before it can read or write anything, while every other request proceeds
normally. Because the function runs inside the request transaction with the
claims already set, it has the full token to reason about.

## Notes and next steps

* **Rotate and protect the secret.** Anyone who holds the JWT secret can
  mint a token for *any* role — treat it like a database password. The
  32-byte minimum is a floor, not a recommendation; use a long random
  secret in production.
* **Set an `exp`.** Tokens without an expiry are valid forever. Give real
  tokens a short lifetime and re-issue them.
* **Audience.** If you set the `jwt_aud` option, Bier additionally requires
  the token's `aud` claim to match, rejecting tokens minted for a different
  service. It is unset (unchecked) by default.
* Every JWT-related knob — `jwt_secret`, `jwt_aud`, `jwt_role_claim_key`,
  `jwt_secret_is_base64`, and the asymmetric (RS/ES/EdDSA) verification Bier
  also supports — is documented in the
  [Configuration guide](../guides/configuration.md).

You now have the whole model: anonymous requests read the catalog as
`web_anon`, and a signed token lets a client act as `brewery_member` and
post check-ins — with PostgreSQL's own grants, not application code, drawing
the line between them. From here the [Configuration guide](../guides/configuration.md)
covers every option, and the [API reference](../guides/api.md)
covers the full query and mutation grammar you can now use as either role.
