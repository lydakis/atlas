{
  lib,
  pkgs,
  ...
}:
{
  atlas.host = {
    enable = true;
    tailscale.enable = true;

    environmentLayers = {
      base.variables = {
        DEMO_BASE = "base";
        DEMO_OVERRIDE = "base";
      };
      dev-tools.packages = {
        git = pkgs.git;
        python = pkgs.python3;
      };
      labblue-git.git.config = {
        init.defaultBranch = "main";
        user = {
          name = "George Lydakis";
          email = "george@labblue.ai";
        };
      };
      node.variables = {
        DEMO_NODE = "enabled";
        DEMO_OVERRIDE = "node";
      };
      personal-git.git.config.user = {
        name = "George Lydakis";
        email = "george@lydakis.me";
      };
    };

    volumes.projects = {
      id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      owner = "operator";
    };

    environments = {
      shared-dev = {
        id = "11111111-1111-4111-8111-111111111111";
        uid = 23001;
        layers = [
          "base"
          "dev-tools"
          "node"
          "labblue-git"
        ];
        git.config.user.email = "atlas@labblue.ai";
        variables = {
          DEMO_API_ORIGIN = "https://example.invalid";
          DEMO_GENERATION = "baseline";
          DEMO_OVERRIDE = "instance";
        };
        volumeMounts.projects.target = "/home/agent/work";
      };

      personal-dev = {
        id = "33333333-3333-4333-8333-333333333333";
        uid = 23003;
        layers = [
          "base"
          "dev-tools"
          "personal-git"
        ];
        volumeMounts.projects.target = "/home/agent/work";
      };

      restricted = {
        id = "22222222-2222-4222-8222-222222222222";
        uid = 23002;
        layers = [ "base" ];
        variables.DEMO_SCOPE = "restricted";
      };
    };
  };

  # The spike deliberately has no ambient login credential. Remote access is
  # enabled only after interactive or runtime-secret Tailscale enrollment.
  users.allowNoPasswordLogin = true;

  documentation.enable = false;

  networking = {
    hostName = "atlas-spike";
    useDHCP = lib.mkDefault true;
  };

  system = {
    stateVersion = "26.05";
    nixos.tags = [ "atlas-spike" ];
  };

  environment.etc."atlas-spike-generation".text = "baseline\n";

  specialisation.atlas-updated.configuration = {
    system.nixos.tags = [ "atlas-spike-update" ];
    environment.etc."atlas-spike-generation".text = lib.mkForce "updated\n";
    atlas.host.environments.shared-dev.variables.DEMO_GENERATION = lib.mkForce "updated";
  };
}
