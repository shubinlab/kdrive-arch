# Contributing

Keep changes focused on the Arch package, installer, runtime contract, or
documentation. Test shell syntax and the package contract before opening a
pull request.

```bash
bash -n install.sh build/*.sh tests/*.sh
bash tests/test-repository-contract.sh
bash tests/test-installer-contract.sh
makepkg --printsrcinfo --dir .
```

Do not commit credentials, host-specific paths, account data, or raw journals.
