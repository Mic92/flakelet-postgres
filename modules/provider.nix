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

  # State hooks for `flakelet export`/`import`, called as root with
  # <claim.json> <dir>. Custom format so restore can reassign ownership.
  dump = pkgs.writeShellApplication {
    name = "flakelet-postgres-dump";
    runtimeInputs = [
      pkgs.jq
      pkgs.util-linux
      pg
    ];
    text = ''
      db=$(jq -r .database "$1")
      runuser -u postgres -- pg_dump --format=custom --no-owner "$db" > "$2/db.pgdump"
    '';
  };

  restore = pkgs.writeShellApplication {
    name = "flakelet-postgres-restore";
    runtimeInputs = [
      pkgs.jq
      pkgs.util-linux
      pg
    ];
    text = ''
      db=$(jq -r .database "$1")
      role=$(jq -r '.role // .database' "$1")
      psql=(runuser -u postgres -- psql --no-psqlrc -qtA -v ON_ERROR_STOP=1)
      # Runs before the exports file exists on this host, so provision here.
      "''${psql[@]}" <<SQL
      SELECT format('CREATE ROLE %I LOGIN', '$role')
        WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') \gexec
      SELECT format('CREATE DATABASE %I OWNER %I', '$db', '$role')
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db') \gexec
      COMMENT ON DATABASE "$db" IS 'flakelet postgres/v1';
      SQL
      # Add-only: never overwrite data that is already there.
      tables=$("''${psql[@]}" -d "$db" -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p','S','v','m') AND n.nspname NOT IN ('pg_catalog','information_schema')")
      if [ "$tables" != 0 ]; then
        echo "flakelet-postgres-restore: database $db is not empty, refusing" >&2
        exit 1
      fi
      runuser -u postgres -- pg_restore --dbname="$db" --no-owner --role="$role" --exit-on-error < "$2/db.pgdump"
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
      state = {
        dump = lib.getExe dump;
        restore = lib.getExe restore;
      };
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
