# flakelet-postgres

The `postgres/v1` contract for [flakelet](https://github.com/Mic92/flakelet)
and its provider. A service claims a database in its exports:

```nix
exports.requires.postgres = {
  database = name; # database to provision
  role = name; # owning role, defaults to the database name
};
```

Access uses peer authentication over the local socket. There is no password
and the connection string is known at evaluation time:
`postgresql://<role>@/<database>?host=/run/postgresql`.

## Users

Postgres maps the connecting OS user to the role of the same name. The unit
therefore needs a static `User=` equal to the claimed role, which rules out
`DynamicUser=`. Declare a system user on the host instead. To use a role
named differently from the database, set `role` in the claim. To use an OS
user named differently from the role, configure
`services.postgresql.identMap` on the host.

The provider requires `services.postgresql.enable` and composes with
`ensureDatabases`. It never drops anything, so rollbacks always find their
database. `flakelet-postgres-orphans` lists databases no active claim covers.

```nix
{
  imports = [ flakelet-postgres.nixosModules.provider ];
  services.flakelet-postgres.enable = true;
}
```

## Export and import

The provider announces `state` hooks, so `flakelet export` carries the
database along: `pg_dump --format=custom` on the source, and on the target
the database and role are created and the dump restored with the claimed
role as owner. Restore refuses a non-empty database.

Schema: [contracts/postgres-v1.json](contracts/postgres-v1.json).

## Development

```console
$ nix build ./tests#checks.x86_64-linux.vm-transfer -L
```
