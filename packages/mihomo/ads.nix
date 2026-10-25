{ pkgs }: pkgs.fetchurl {
  # Domain-behavior YAML seed for an HTTP rule-provider. Runtime updates keep
  # their own cache; this pinned asset permits the first start without network.
  name = "mihomo-category-ads-all.yaml";
  url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/2d368ff6025f49e068e848487bac54056e123a79/geo/geosite/category-ads-all.yaml";
  hash = "sha256-ZMq/WAB9P+sFqVT6tAJ/6QvVcBo2Tz9Pvw/9tEFvD7U=";
}
