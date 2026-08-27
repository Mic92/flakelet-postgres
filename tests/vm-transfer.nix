# export on node a, import on node b: the provider's dump/restore hooks
# carry the database contents along with the service.
{ flakeletModule, providerModule }:
{ pkgs, lib, ... }:
let
  testService = pkgs.writeTextDir "flake.nix" ''
    {
      outputs = _: {
        flakelets.default =
          { types, ... }:
          {
            impl =
              { pkgs, name, ... }:
              {
                services.''${name} = {
                  wantedBy = [ "multi-user.target" ];
                  after = [ "postgresql.target" ];
                  serviceConfig = {
                    ExecStart = "''${pkgs.coreutils}/bin/sleep infinity";
                    User = name;
                    StateDirectory = name;
                    Restart = "on-failure";
                  };
                };
                exports.requires.postgres = { database = name; };
              };
          };
      };
    }
  '';
  node =
    { config, options, ... }:
    {
      imports = [
        flakeletModule
        providerModule
      ];
      services.postgresql.enable = true;
      services.flakelet-postgres.enable = true;
      services.flakelets = {
        enable = true;
        services.web.flake = "path:${testService}";
      };
      users.users.web = {
        isSystemUser = true;
        group = "web";
      };
      users.groups.web = { };
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        substituters = lib.mkForce [ ];
      };
      virtualisation = {
        writableStore = true;
        additionalPaths = [
          config.services.flakelets.nixpkgs
          testService
          pkgs.stdenvNoCC
          pkgs.bash
          pkgs.coreutils
        ];
        memorySize = 4096;
        cores = 4;
      }
      // lib.optionalAttrs (options.virtualisation ? virtiofs) { virtiofs.enable = true; };
    };
  psql =
    user: db: sql:
    "runuser -u ${user} -- psql -qtAX -v ON_ERROR_STOP=1 -d ${db} -c ${lib.escapeShellArg sql}";
  # Shell snippets become Python string literals; Nix and Python agree on \" escaping.
  py = lib.strings.escapeNixString;
in
{
  name = "flakelet-postgres-transfer";
  nodes.a = node;
  nodes.b = node;

  testScript = ''
    start_all()
    a.wait_for_unit("postgresql.target")
    a.succeed("systemctl start flakelet-web.service", timeout=600)
    a.wait_until_succeeds(${py "${psql "postgres" "postgres" "SELECT 1 FROM pg_database WHERE datname='web'"} | grep -q 1"})
    a.succeed(${py (psql "web" "web" "CREATE TABLE t(v text); INSERT INTO t VALUES ('payload')")})

    a.succeed("flakelet export web --dry-run >&2")
    a.succeed("flakelet export web > /tmp/shared/web.tar.zst")
    print(a.succeed("tar --zstd -tf /tmp/shared/web.tar.zst"))
    a.succeed("tar --zstd -tf /tmp/shared/web.tar.zst | grep -q requires/postgres/db.pgdump")

    b.wait_for_unit("postgresql.target")
    b.succeed("flakelet import - --no-refresh < /tmp/shared/web.tar.zst >&2", timeout=600)
    b.succeed("systemctl is-active web.service")
    # Data arrived and the claimed role owns it, so peer auth works as on a.
    b.succeed(${py "${psql "web" "web" "SELECT v FROM t"} | grep -qx payload"})
    b.succeed(${py "${psql "postgres" "web" "SELECT tableowner FROM pg_tables WHERE tablename='t'"} | grep -qx web"})
    b.succeed(${py "${psql "postgres" "postgres" "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname='web'"} | grep -q flakelet"})

    # Add-only: a second restore into the now non-empty database is refused.
    b.succeed("flakelet remove --purge web")
    b.fail("flakelet import /tmp/shared/web.tar.zst --no-refresh")
  '';
}
