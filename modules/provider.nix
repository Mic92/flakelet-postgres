# Level-triggered provider for the postgres/v1 contract: creates roles
# and databases claimed via exports.requires.postgres. Add-only: nothing is
# ever dropped, orphans are listed by `flakelet-postgres-orphans`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.flakelet-postgres;
  pg = config.services.postgresql.package;

  provision = pkgs.writeShellApplication {
    name = "flakelet-postgres-provision";
    runtimeInputs = [
      pkgs.jq
      pg
    ];
    text = ''
      shopt -s nullglob
      {
        echo 'CREATE TEMP TABLE claims(db text, role text);'
        echo 'COPY claims FROM STDIN;'
        jq -r '.requires.postgres // empty | [.database, (.role // .database)] | @tsv' \
          ${cfg.exportsDir}/*.json /dev/null
        echo '\.'
        cat <<'SQL'
      SELECT DISTINCT format('CREATE ROLE %I LOGIN', role) FROM claims c
        WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = c.role) \gexec
      SELECT DISTINCT format('CREATE DATABASE %I OWNER %I', db, role) FROM claims c
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = c.db) \gexec
      -- Ownership marker so orphans only reports databases a claim managed.
      SELECT DISTINCT format('COMMENT ON DATABASE %I IS $$flakelet postgres/v1$$', db)
        FROM claims \gexec
      SQL
      } | psql --no-psqlrc -v ON_ERROR_STOP=1
    '';
  };

  orphans = pkgs.writeShellApplication {
    name = "flakelet-postgres-orphans";
    runtimeInputs = [
      pkgs.jq
      pg
    ];
    text = ''
      shopt -s nullglob
      {
        echo 'CREATE TEMP TABLE claims(db text, role text);'
        echo 'COPY claims FROM STDIN;'
        jq -r '.requires.postgres // empty | [.database, (.role // .database)] | @tsv' \
          ${cfg.exportsDir}/*.json /dev/null
        echo '\.'
        echo "SELECT datname FROM pg_database\
          WHERE shobj_description(oid, 'pg_database') = 'flakelet postgres/v1'\
          AND datname NOT IN (SELECT db FROM claims);"
      } | psql --no-psqlrc -qtA -v ON_ERROR_STOP=1
    '';
  };
in
{
  options.services.flakelet-postgres = {
    enable = lib.mkEnableOption "the provider for the postgres/v1 flakelet contract";
    exportsDir = lib.mkOption {
      type = lib.types.path;
      default = "/run/flakelet/exports";
      description = "Directory of published flakelet exports.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Guest: composes with ensureDatabases, never configures postgres itself.
    assertions = [
      {
        assertion = config.services.postgresql.enable;
        message = "services.flakelet-postgres requires services.postgresql.enable";
      }
    ];

    environment.etc."flakelet/providers.d/postgres-v1.json".text = builtins.toJSON {
      contract = "postgres/v1";
    };

    environment.systemPackages = [ orphans ];

    systemd.services.flakelet-postgres-provision = {
      description = "provision databases claimed via flakelet postgres/v1";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.target" ];
      requires = [ "postgresql.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        ExecStart = lib.getExe provision;
      };
    };

    systemd.paths.flakelet-postgres-provision = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = cfg.exportsDir;
    };
  };
}
