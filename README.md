# Primal Fi Smart Contracts

A modular liquid staking protocol built for the native ApeCoin ecosystem on ApeChain.

---

# Overview

This repository contains the core smart contracts powering **Primal Fi**.

The protocol introduces:

* Liquid staking mechanics using `prAPE`
* Dynamic reward distribution through a liquidity index model
* Transferable staking positions
* Auto-merging stake architecture
* Queue-based withdrawals
* Emergency protocol modes
* Scaled balance accounting

The repository includes:

* Core protocol contracts
* Token contracts
* ABI JSON files
* Main staking and reward logic

---

# Contracts

## `PrimalProtocol.sol`

Main staking and reward distribution contract.

### Features

* Native ApeCoin staking on ApeChain
* 30 / 60 / 90 day lock periods
* Liquidity index reward model
* Reward injection & distribution
* Withdraw queue system
* Early withdrawal penalties
* Emergency withdrawal mode
* Transferable staking positions
* Automatic stake merging
* Ring-buffer withdraw queue architecture
* Scaled accounting system

---

## `PrimalApe.sol`

ERC20 liquid staking token (`prAPE`).

### Features

* ERC20 compatible
* Dynamic balance growth
* Scaled balance accounting
* Transfer-linked stake ownership syncing
* Protocol-controlled mint/burn
* Pause system
* Real-time indexed balances

---

# Protocol Architecture

## Liquid Staking

Users stake native ApeCoin into the protocol and receive:

`prAPE`

The token represents a proportional share of the protocol’s underlying liquidity.

As rewards are distributed, the protocol liquidity index increases, causing all `prAPE` balances to appreciate automatically.

---

# Reward System

The protocol uses a **scaled balance + liquidity index model** inspired by advanced DeFi liquidity protocols.

### Reward Flow

1. Rewards are injected into the reserve
2. Rewards are distributed through the liquidity index
3. All holders automatically gain value
4. No rebasing required

---

# Main Components

## Liquidity Index

Tracks protocol growth over time.

The index increases whenever rewards are distributed.

Users maintain scaled balances internally while visible balances grow dynamically.

---

## Stake Positions

Each stake stores:

* Owner
* Deposited amount
* Scaled amount
* Unlock timestamp
* Lock period
* Active state

---

## Auto Merge System

Stakes with matching:

* owner
* unlock time
* lock period

are automatically merged to reduce storage fragmentation and optimize gas usage.

---

## Withdraw Queue

Withdrawals are processed through a queue system with:

* minimum queue time
* delayed claim mechanism
* ring-buffer storage optimization
* automatic cleanup logic

---

# Security Features

* `ReentrancyGuard`
* `Ownable`
* Emergency protocol modes
* Queue protection
* Transfer iteration limits
* Overflow protections
* Safe liquidity index updates
* Anti-dust safeguards
* Treasury isolation

---

# Protocol Modes

The protocol supports multiple operational states:

| Mode              | Description                |
| ----------------- | -------------------------- |
| Live              | Full functionality         |
| DepositsPaused    | Deposits disabled          |
| WithdrawalsPaused | Withdrawals disabled       |
| EmergencyOnly     | Emergency withdrawals only |

---

# Core Mechanics

## Staking

Users stake native ApeCoin and receive:

* `prAPE`
* transferable staking exposure
* auto-accruing rewards

---

## Transfers

When `prAPE` is transferred:

* staking positions are synchronized
* ownership updates internally
* partial stake splitting is supported
* full stake transfers are supported

---

## Reward Distribution

Rewards can be:

* injected into reserve
* partially distributed
* fully distributed

Distribution increases the protocol liquidity index.

---

# Repository Structure

```bash
/Core Contracts
  ├── PrimalProtocol.sol
  └── prAPE.sol

/ABI Core Contracts
  ├── PrimalProtocol.json
  └── prAPE.json
```

---

# Dependencies

Built using:

* Solidity `^0.8.20`
* OpenZeppelin Contracts

Main imports:

```solidity
@openzeppelin/contracts/access/Ownable.sol
@openzeppelin/contracts/utils/ReentrancyGuard.sol
@openzeppelin/contracts/token/ERC20/ERC20.sol
```

---

# Deployment Order

## 1. Deploy `PrimalApe`

```solidity
PrimalApe
```

---

## 2. Deploy `PrimalProtocol`

Constructor:

```solidity
constructor(address _prAPE, address _treasury)
```

Parameters:

* `_prAPE` → deployed PrimalApe address
* `_treasury` → treasury wallet

---

## 3. Connect Token To Protocol

Call:

```solidity
setProtocol(address protocol)
```

on `PrimalApe`.

---

# Example Flow

## Stake

```solidity
stake(uint256 period)
```

Accepted periods:

* 30 days
* 60 days
* 90 days

---

## Request Withdraw

```solidity
requestWithdraw(uint256 stakeIndex)
```

---

## Claim Withdraw

```solidity
claimWithdraw(uint256 index, uint256 requestId)
```

---

## Inject Rewards

```solidity
injectRewards()
```

---

## Distribute Rewards

```solidity
distributeRewards()
```

or

```solidity
distributeAllRewards()
```

---

# Important Notes

* `prAPE` balances dynamically grow over time
* Internal accounting uses scaled balances
* Transfers synchronize staking ownership
* Withdrawals use delayed queue processing
* Emergency mode bypasses queue delays
* Rewards are index-based, not rebasing
* Designed specifically for ApeChain native liquidity mechanics

---

# License

MIT License
