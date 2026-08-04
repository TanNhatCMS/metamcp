module.exports = {
  hooks: {
    readPackage(pkg) {
      if (pkg.name === "@hookform/resolvers" && pkg.peerDependencies) {
        pkg.peerDependencies["ajv-formats"] = "*";
      }
      if (pkg.name === "next-runtime-env" && pkg.peerDependencies) {
        pkg.peerDependencies["next"] = "*";
        pkg.peerDependencies["react"] = "*";
      }
      return pkg;
    },
  },
};
