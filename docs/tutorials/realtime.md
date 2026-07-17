# Realtime: a live check-ins board

This chapter continues the brewery from [Getting started](getting-started.md)
and builds on the `brewery_member` setup from
[Authentication](authentication.md) (schema in `docs/tutorials/brewery.sql`).
Regulars already post check-ins as `brewery_member`; now we'll push each new
one to a browser the moment it lands — a live check-ins board — using
nothing but a trigger and Bier's SSE endpoint.

## 1. Expose a channel

Add `events_channels` to the options you already booted Bier with in
[Getting started](getting-started.md) (or
[Authentication](authentication.md), if you've since added `jwt_secret`) —
every other option stays as it was:

```elixir
{Bier,
 name: Tutorial,
 router: [port: 4040, scheme: :http],
 db_schemas: ["api"],
 events_channels: ["new_check_ins"]}
```

## 2. Notify on insert

The payload is a key, not the row — NOTIFY payloads are capped at 8000
bytes, and sending just the id lets the client fetch exactly the columns it
wants through the API it already knows. Add this trigger to your database:

```sql
create or replace function api.notify_new_check_in()
returns trigger language plpgsql as $$
begin
  perform pg_notify('new_check_ins', new.id::text);
  return new;
end;
$$;

create trigger check_ins_notify
  after insert on api.check_ins
  for each row execute function api.notify_new_check_in();
```

## 3. Listen in the browser

```javascript
const es = new EventSource("/events?channel=new_check_ins");

es.addEventListener("new_check_ins", async (e) => {
  // web_anon has `select` on both check_ins and beers (needed for the
  // embed), so this fetch works with no token even though posting one
  // does not.
  const res = await fetch(
    `/check_ins?id=eq.${e.data}&select=id,drinker,rating,comment,beers(name)`
  );
  const [checkIn] = await res.json();
  renderRow(checkIn); // your UI code
});
```

## 4. Try it

Posting still requires the `brewery_member` token from
[Authentication](authentication.md#mint-a-token) — mint one there if you
don't already have `$TOKEN` set:

```bash
curl -X POST "http://localhost:4040/check_ins" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"beer_id": 2, "drinker": "jamie", "rating": 4, "comment": "Hazy and delicious"}'
```

The `new_check_ins` event fires, the browser fetches the row — beer name and
all — and the board updates: no polling, no extra realtime service.

For authentication, multiplexing several channels, delivery caveats, and
telemetry, see the [Realtime events guide](../guides/realtime_events.md).
