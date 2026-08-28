# export on machine a, import on machine b: the provider's dump/restore
# hooks carry the database contents along with the service.
{
  flakeletModule,
  providerModule,
  buildArtifact,
}:
{ pkgs, lib, ... }:
let
  # Prebuilt on the host: nspawn test containers have no writable store.
  web = buildArtifact pkgs {
    name = "web";
    module =
      { ... }:
      {
        impl =
          { inputs, ... }:
          let
            inherit (inputs.nixpkgs) pkgs;
            inherit (inputs.flakelet) name;
          in
          {
            services.${name} = {
              wantedBy = [ "multi-user.target" ];
              after = [ "postgresql.target" ];
              serviceConfig = {
                ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
                User = name;
                StateDirectory = name;
              };
            };
            exports.requires.postgres = {
              database = name;
            };
          };
      };
  };
  node = {
    imports = [
      flakeletModule
      providerModule
    ];
    services.postgresql.enable = true;
    services.flakelet-postgres.enable = true;
    services.flakelets = {
      enable = true;
      services.web.prebuilt = web;
    };
    users.users.web = {
      isSystemUser = true;
      group = "web";
    };
    users.groups.web = { };
  };
  psql =
    user: db: sql:
    "runuser -u ${user} -- psql -qtAX -v ON_ERROR_STOP=1 -d ${db} -c ${lib.escapeShellArg sql}";
  # Shell snippets become Python string literals; Nix and Python agree on \" escaping.
  py = lib.strings.escapeNixString;
in
{
  name = "flakelet-postgres-transfer";
  containers = {
    a = node;
    b = node;
  };

  testScript = ''
    start_all()
    a.wait_for_unit("postgresql.target")
    a.wait_for_unit("web.service", timeout=600)
    a.succeed(${py "${psql "postgres" "postgres" "SELECT 1 FROM pg_database WHERE datname='web'"} | grep -q 1"})
    a.succeed(${py (psql "web" "web" "CREATE TABLE t(v text); INSERT INTO t VALUES ('payload')")})

    a.succeed("flakelet export web --dry-run >&2")
    a.succeed("flakelet export web --to b > /tmp/shared/web.tar.zst")
    a.fail("systemctl is-active web.service")
    a.succeed("tar --zstd -tf /tmp/shared/web.tar.zst | grep -q requires/postgres/db.pgdump")

    b.wait_for_unit("postgresql.target")
    # b declares and runs web itself (prebuilt) on an empty database.
    b.wait_for_unit("web.service", timeout=600)
    b.succeed("flakelet import - < /tmp/shared/web.tar.zst >&2", timeout=600)
    b.succeed("systemctl is-active web.service")
    # Data arrived and the claimed role owns it, so peer auth works as on a.
    b.succeed(${py "${psql "web" "web" "SELECT v FROM t"} | grep -qx payload"})
    b.succeed(${py "${psql "postgres" "web" "SELECT tableowner FROM pg_tables WHERE tablename='t'"} | grep -qx web"})
    b.succeed(${py "${psql "postgres" "postgres" "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname='web'"} | grep -q flakelet"})

    # Add-only: a second restore into the now non-empty database is refused
    # and leaves web disabled. --replace drops and restores it.
    b.fail("flakelet import /tmp/shared/web.tar.zst >&2")
    b.fail("systemctl is-active web.service")
    b.succeed("flakelet import --replace /tmp/shared/web.tar.zst >&2", timeout=600)
    b.succeed("systemctl is-active web.service")
    b.succeed(${py "${psql "web" "web" "SELECT v FROM t"} | grep -qx payload"})
  '';
}
