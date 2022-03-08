# <h1 align="center"> FIAT Vaults 🏺 </h1>

**Repository containing the Vault smart contracts of FIAT**

## Requirements
If you do not have DappTools already installed, you'll need to run the 
commands below

### Install Nix

```sh
# User must be in sudoers
curl -L https://nixos.org/nix/install | sh

# Run this or login again to use Nix
. "$HOME/.nix-profile/etc/profile.d/nix.sh"
```

### Install DappTools
```sh
nix-env -f https://github.com/dapphub/dapptools/archive/f9ff55e11100b14cd595d8c15789d8407124b349.tar.gz -iA dapp hevm seth ethsign
```

### Set .env
Copy and update contents from `.env.example` to `.env`

## Building and testing

```sh
git clone https://github.com/fiatdao/vaults
cd vaults
make # This installs the project's dependencies.
make test
```
