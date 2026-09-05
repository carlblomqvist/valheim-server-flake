{
  self,
  steam-fetcher,
}: {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.valheimInstances;
  stateRoot = "/var/lib/valheim";

  instances = lib.filterAttrs (_: instance: instance.enable) cfg;
  instanceNames = builtins.attrNames instances;
  instanceList = builtins.attrValues instances;

  # Every instance claims `port` and `port + 1`, so two instances less than two
  # apart overlap even when their game ports differ.
  portConflicts = let
    named =
      lib.mapAttrsToList (name: instance: {
        inherit name;
        inherit (instance) port;
      })
      instances;
  in
    lib.concatMap (
      a:
        lib.concatMap (
          b:
            lib.optional
            (a.name < b.name && (a.port - b.port) < 2 && (b.port - a.port) < 2)
            "${a.name} (port ${toString a.port}) and ${b.name} (port ${toString b.port})"
        )
        named
    )
    named;

  instanceModule = {name, ...}: {
    options = {
      enable =
        lib.mkEnableOption (lib.mdDoc "this Valheim server instance")
        // {default = true;};

      serverName = lib.mkOption {
        type = lib.types.str;
        default = name;
        example = "Some Cozy Server";
        description = lib.mdDoc "The name listed in the server browser.";
      };

      worldName = lib.mkOption {
        type = with lib.types; nullOr str;
        default = name;
        example = "Midgard";
        description = lib.mdDoc ''
          The name of the world file to use, without the extension.
          If the world does not exist, then the server will generate a world from
          a random seed.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        example = 2456;
        description = lib.mdDoc ''
          The port on which to listen for incoming connections.

          Note that the port just above this one is used as the Steam query port,
          so instance ports must be at least 2 apart.
        '';
      };

      crossplay = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = lib.mdDoc ''
          Whether to enable cross-platform players.

          This should be disabled when using a modded server that requires the
          client to be modded, as only PC versions can run mods.
        '';
      };

      noGraphics = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = lib.mdDoc ''
          Whether to run with graphics or not.
          Enable this if you're headless with no GPU.
        '';
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = lib.mdDoc "Whether to open ports in the firewall.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = lib.mdDoc ''
          Toggles visibility on the Steam server & community lists.
        '';
      };

      preset = lib.mkOption {
        type = with lib.types; nullOr (enum ["easy" "hard" "hardcore" "casual" "hammer" "immersive"]);
        default = null;
        example = "hardcore";
        description = lib.mdDoc ''
          The preset world modifier, valid options are
          "easy", "hard", "hardcore", "casual", "hammer" and "immersive".
        '';
      };

      modifiers = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = {};
        example = {
          portals = "casual";
          raids = "none";
        };
        description = lib.mdDoc ''
          Individual world modifiers, passed as `-modifier <key> <value>`.

          Keys are "combat", "deathpenalty", "resources", "raids" and
          "portals". These are applied on top of {option}`preset`.
        '';
      };

      password = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = lib.mdDoc ''
          The server password.

          This is passed as a commandline argument to the server, so it
          can be viewed by any user on the system able to list processes.
        '';
      };

      passwordEnvFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        example = "/var/lib/valheim/password.env";
        description = lib.mdDoc ''
          Path to a file containing the server password in env format.

          Example:
          VH_SERVER_PASSWORD='myp@$$'
        '';
      };

      adminList = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        example = [
          "72057602627862526"
          "72057602627862527"
        ];
        description = lib.mdDoc ''
          List of Steam IDs to be added to the adminlist.txt file.

          These users will have admin privileges on the server.
        '';
      };

      permittedList = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = lib.mdDoc ''
          List of Steam IDs to be added to the permittedlist.txt file.

          Only these users will be allowed to join the server if the list is not empty.
        '';
      };

      bannedList = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = lib.mdDoc ''
          List of Steam IDs to be added to the bannedlist.txt file.

          These users will be banned from the server.
        '';
      };

      bepinexMods = lib.mkOption {
        type = with lib; types.listOf types.package;
        default = [];
        description = lib.mdDoc "BepInEx mods to install.";
        example = lib.types.literalExpression ''
          [
            (pkgs.fetchValheimThunderstoreMod {
              owner = "Somebody";
              name = "SomeMod";
              version = "x.y.z";
              hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            })
          ]
        '';
      };

      bepinexConfigs = lib.mkOption {
        type = with lib; types.listOf types.path;
        default = [];
        description = lib.mdDoc ''
          Config files for BepInEx mods.

          The filename must be what the given mod is expecting, otherwise it will
          not be loaded.
        '';
        example = lib.types.literalExpression ''
          [
            ./some_mod.cfg
          ]
        '';
      };
    };
  };

  mkInstanceService = name: instance: let
    instanceDir = "${stateRoot}/${name}";
    installDir = "${instanceDir}/valheim-server-modded";
    gameDataDir = "${instanceDir}/.config/unity3d/IronGate/Valheim";
    modded = instance.bepinexMods != [];

    # If passwordEnvFile is provided then use environment variable, else insert
    # password in unit file directly.  Assertions ensure that other cases are
    # not possible.
    serverPassword =
      if instance.passwordEnvFile != null
      then "\"\${VH_SERVER_PASSWORD}\""
      else instance.password;

    mods = pkgs.symlinkJoin {
      name = "valheim-bepinex-mods-${name}";
      paths = instance.bepinexMods;
      postBuild = ''
        rm -f \
          "$out"/*.md \
          "$out"/icon.png \
          "$out"/manifest.json
      '';
    };

    modConfigs =
      pkgs.runCommandLocal "valheim-bepinex-configs-${name}" {
        configs = instance.bepinexConfigs;
      } ''
        mkdir "$out"
        for cfg in $configs; do
          cp $cfg $out/$(stripHash $cfg)
        done
      '';

    createListFile = listName: list: ''
      printf '%s\n' "// List of Steam IDs for ${listName} ONE per line" ${lib.escapeShellArgs list} \
        > ${gameDataDir}/${listName}
    '';

    bepinexWrapper = pkgs.buildFHSEnv {
      name = "valheim-server-${name}";
      runScript = pkgs.writeScript "valheim-server-bepinex-wrapper-${name}" ''
        # Whether or not to enable Doorstop. Valid values: TRUE or FALSE
        export DOORSTOP_ENABLED=1

        # What .NET assembly to execute. Valid value is a path to a .NET DLL that mono can execute.
        export DOORSTOP_TARGET_ASSEMBLY="${installDir}/BepInEx/core/BepInEx.Preloader.dll"

        export LD_LIBRARY_PATH=${installDir}/doorstop_libs:$LD_LIBRARY_PATH
        export LD_PRELOAD="libdoorstop_x64.so"

        export LD_LIBRARY_PATH=${pkgs.steamworks-sdk-redist}/lib:$LD_LIBRARY_PATH
        export SteamAppId=892970

        exec ${installDir}/valheim_server.x86_64 "$@"
      '';

      targetPkgs = _:
        with pkgs; [
          steamworks-sdk-redist
          zlib
          pulseaudio
        ];
    };

    serverBin =
      if modded
      then "${bepinexWrapper}/bin/valheim-server-${name}"
      else "${pkgs.valheim-server}/bin/valheim-server";
  in
    lib.nameValuePair "valheim-${name}" {
      description = "Valheim dedicated server (${name})";
      requires = ["network.target"];
      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      # The server derives every data path from $HOME, so pointing it at the
      # instance directory is what keeps worlds and lists separated.
      environment.HOME = instanceDir;

      preStart =
        ''
          mkdir -p ${gameDataDir}
          ${createListFile "adminlist.txt" instance.adminList}
          ${createListFile "permittedlist.txt" instance.permittedList}
          ${createListFile "bannedlist.txt" instance.bannedList}
        ''
        + lib.optionalString modded ''
          if [ -e ${installDir} ]; then
            chmod -R +w ${installDir}
            rm -rf ${installDir}
          fi
          mkdir ${installDir}
          cp -r \
            ${pkgs.valheim-server-unwrapped}/* \
            ${pkgs.valheim-bepinex-pack}/* \
            ${installDir}

          # BepInEx doesn't like read-only files.
          chmod -R u+w ${installDir}

          # Install extra mods.
          cp -rL "${mods}"/. ${installDir}/BepInEx/plugins/

          # BepInEx *really* doesn't like *any* read-only files.
          chmod -R u+w ${installDir}/BepInEx/plugins/
        ''
        + lib.optionalString (instance.bepinexConfigs != []) ''
          # Install extra mod configs.
          cp -r ${modConfigs}/. ${installDir}/BepInEx/config/

          # BepInEx *really* doesn't like *any* read-only files.
          chmod -R u+w ${installDir}/BepInEx/config/
        '';

      serviceConfig = {
        Type = "exec";
        User = "valheim";
        Group = "valheim";
        StateDirectory = "valheim/${name}";
        EnvironmentFile = lib.mkIf (instance.passwordEnvFile != null) instance.passwordEnvFile;
        ExecStart = lib.strings.concatStringsSep " " ([
            serverBin
            "-name \"${instance.serverName}\""
            "-batchmode"
          ]
          ++ (lib.lists.optional (instance.worldName != null) "-world \"${instance.worldName}\"")
          ++ [
            "-port \"${builtins.toString instance.port}\""
            "-password ${serverPassword}"
            "-public ${
              if instance.public
              then "1"
              else "0"
            }"
          ]
          ++ (lib.lists.optional instance.crossplay "-crossplay")
          ++ (lib.lists.optional (instance.preset != null) "-preset \"${instance.preset}\"")
          ++ (lib.attrsets.mapAttrsToList (key: value: "-modifier \"${key}\" \"${value}\"") instance.modifiers)
          ++ (lib.lists.optional instance.noGraphics "-nographics"));
      };
    };
in {
  options.services.valheimInstances = lib.mkOption {
    type = with lib.types; attrsOf (submodule instanceModule);
    default = {};
    description = lib.mdDoc ''
      Valheim dedicated server instances, keyed by name.

      Each instance gets its own systemd unit (`valheim-<name>`), its own state
      directory under `${stateRoot}`, and its own port.  Instances share the
      `valheim` system user.

      This is independent of {option}`services.valheim`, which runs a single
      server out of `${stateRoot}` directly.  Do not enable both.
    '';
    example = lib.literalExpression ''
      {
        midgard = {
          port = 2456;
          noGraphics = true;
          openFirewall = true;
        };
        modded = {
          port = 2458;
          noGraphics = true;
          openFirewall = true;
        };
      }
    '';
  };

  config = {
    nixpkgs.overlays = [self.overlays.default steam-fetcher.overlays.default];

    users = lib.mkIf (instanceNames != []) {
      users.valheim = {
        isSystemUser = true;
        group = "valheim";
        home = stateRoot;
        createHome = true;
      };
      groups.valheim = {};
    };

    systemd.services = lib.mapAttrs' mkInstanceService instances;

    networking.firewall.allowedUDPPorts =
      lib.concatMap (
        instance:
          lib.optionals instance.openFirewall [
            instance.port
            (instance.port + 1) # Steam query port
          ]
      )
      instanceList;

    assertions =
      [
        {
          assertion = !((config.services.valheim.enable or false) && instanceNames != []);
          message = "services.valheim and services.valheimInstances both manage ${stateRoot}; enable only one of them.";
        }
        {
          assertion = portConflicts == [];
          message = ''
            Overlapping services.valheimInstances ports: ${lib.concatStringsSep ", " portConflicts}.
            Each instance claims its port and the Steam query port just above it,
            so instance ports must be at least 2 apart.
          '';
        }
      ]
      ++ lib.concatMap (name: let
        instance = instances.${name};
      in [
        {
          assertion = instance.serverName != "";
          message = "The server name for services.valheimInstances.${name} must not be empty.";
        }
        {
          assertion = instance.worldName != "";
          message = "The world name for services.valheimInstances.${name} must not be empty.";
        }
        {
          assertion = (instance.password != null && instance.password != "") != (instance.passwordEnvFile != null);
          message = "Please provide either password or passwordEnvFile for services.valheimInstances.${name}, but not both.";
        }
      ])
      instanceNames;
  };
}
