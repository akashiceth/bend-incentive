import { ethers, upgrades } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { waitForTx } from "./utils";
import { MAX_UINT_AMOUNT, ONE_YEAR } from "./constants";

export async function deployBendToken(vault: Contract, amount: BigNumber) {
  return deployProxyContract("BendToken", [vault.address, amount]);
}

export async function deployBendTokenTester(
  vault: Contract,
  amount: BigNumber
) {
  return await deployProxyContract("BendTokenTester", [vault.address, amount]);
}

export async function deployVault() {
  return await deployContract("Vault");
}

export async function deployIncentivesController(
  bendToken: Contract,
  vault: Contract
) {
  const incentivesController = await deployProxyContract(
    "BendProtocolIncentivesController",
    [bendToken.address, vault.address, ONE_YEAR * 100]
  );
  await waitForTx(
    await vault.approve(
      bendToken.address,
      incentivesController.address,
      MAX_UINT_AMOUNT
    )
  );
  return incentivesController;
}

export async function deployVeBend(bendToken: Contract) {
  return await deployProxyContract("VeBend", [bendToken.address]);
}

export async function deployFeeDistributor(
  lendPoolAddressesProvider: Contract,
  vebend: Contract,
  weth: Contract,
  bendCollector: string,
  bToken: Contract
) {
  return await deployProxyContract("FeeDistributorTester", [
    weth.address,
    bToken.address,
    vebend.address,
    lendPoolAddressesProvider.address,
    bendCollector,
  ]);
}

export async function deployLockupBend(
  weth: Contract,
  bendToken: Contract,
  vebend: Contract,
  feeDistributor: Contract,
  delegation: Contract
) {
  return await deployContract("LockupBend", [
    weth.address,
    bendToken.address,
    vebend.address,
    feeDistributor.address,
    delegation.address,
  ]);
}

export async function deployMerkleDistributor(bendToken: Contract) {
  return await deployProxyContract("MerkleDistributor", [bendToken.address]);
}

export async function deployProxyContract(name: string, args?: unknown[]) {
  const _f = await ethers.getContractFactory(name);
  const _c = await upgrades.deployProxy(_f, args);
  await _c.deployed();

  return _c;
}

export async function deployContract(name: string, args: unknown[] = []) {
  const _f = await ethers.getContractFactory(name);
  const _c = await _f.deploy(...args);
  await _c.deployed();
  return _c;
}
