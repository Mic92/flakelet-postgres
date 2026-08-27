# Provider for the postgres/v1 contract: creates the role and database a
# service claims via exports.requires.postgres. flakelet calls `provision`
# before starting the service. Add-only: nothing is ever dropped, orphans
# are listed by `flakelet-postgres-orphans`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.flakelet-postgres;
  pg = config.services.postgresql.package;

  # All hooks are called by flakelet as root with <claim.json> [<dir>].
  hook =
    name: text:
    pkgs.writeShellApplication {
      name = "flakelet-postgres-${name}";
      runtimeInputs = [
        pkgs.jq
        pkgs.util-linux
        pg
      ];
      text = ''
        db=$(jq -r .database "$1")
        role=$(jq -r '.role // .database' "$1")
        psql() { runuser -u postgres -- psql --no-psqlrc -qtAX -v ON_ERROR_STOP=1 "$@"; }
        export db role
        ${text}
      '';
    };

  provision = hook "provision" ''
    psql -d postgres <<SQL
    SELECT format('CREATE ROLE %I LOGIN', '$role')
      WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') \gexec
    SELECT format('CREATE DATABASE %I OWNER %I', '$db', '$role')
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db') \gexec
    -- marker so orphans only lists databases a claim created
    COMMENT ON DATABASE "$db" IS 'flakelet postgres/v1';
    SQL
  '';

  # Custom format so restore can reassign ownership.
  dump = hook "dump" ''
    runuser -u postgres -- pg_dump --format=custom --no-owner "$db" > "$2/db.pgdump"
  '';

  restore = hook "restore" ''
    ${lib.getExe provision} "$1"
    # Add-only: never overwrite data that is already there.
    tables=$(psql -d "$db" -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p','S','v','m') AND n.nspname NOT IN ('pg_catalog','information_schema')")
    if [ "$tables" != 0 ]; then
      echo "flakelet-postgres-restore: database $db is not empty, refusing" >&2
      exit 1
    fi
    runuser -u postgres -- pg_restore --dbname="$db" --no-owner --role="$role" --exit-on-error < "$2/db.pgdump"
  '';

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
      provision = lib.getExe provision;
      state = {
        dump = lib.getExe dump;
        restore = lib.getExe restore;
      };
    };

    environment.systemPackages = [ orphans ];

    systemd.targets.flakelet-providers = {
      wants = [ "postgresql.target" ];
      after = [ "postgresql.target" ];
    };
  };
}
