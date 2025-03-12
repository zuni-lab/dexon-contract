# Dexon Protocol [![Github Actions][gha-badge]][gha] [![Foundry][foundry-badge]][foundry] [![License: MIT][license-badge]][license]

[gha]: https://github.com/zuni-lab/dexon-contract/actions
[gha-badge]: https://github.com/zuni-lab/dexon-contract/actions/workflows/ci.yml/badge.svg
[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg
[license]: https://opensource.org/licenses/MIT
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg

Dexon is a decentralized order execution protocol built on top of Uniswap V3, enabling advanced trading features like
limit orders, stop orders, and TWAP (Time-Weighted Average Price) orders.

## Features

### Order Types

- **Limit Orders**: Execute trades when an asset reaches a specific price
- **Stop Orders**: Trigger trades when price crosses a threshold
- **TWAP Orders**: Split large orders into smaller parts executed over time
- **Market Orders**: Direct execution through Uniswap V3 pools

### Key Capabilities

- EIP-712 compliant signatures for gasless order submission
- Price feeds using Uniswap V3 TWAP oracles
- Multi-hop swaps support (up to 2 hops via WETH)
- Customizable slippage protection
- Nonce-based replay protection

## Technical Overview

### Smart Contracts

```solidity
contract Dexon is EIP712 {
    // Core order types
    struct Order {
        address account;
        uint256 nonce;
        bytes path;
        uint256 amount;
        uint256 triggerPrice;
        uint256 slippage;
        OrderType orderType;
        OrderSide orderSide;
        uint256 deadline;
        bytes signature;
    }

    struct TwapOrder {
        address account;
        uint256 nonce;
        bytes path;
        uint256 amount;
        OrderSide orderSide;
        uint256 interval;
        uint256 totalOrders;
        uint256 startTimestamp;
        bytes signature;
    }
}
```

### Architecture

1. **Order Execution**

   - Validates order signatures and conditions
   - Checks price triggers against Uniswap V3 oracle
   - Executes swaps through Uniswap V3 Router
   - Handles token transfers and approvals

2. **TWAP Execution**

   - Splits orders into multiple parts
   - Enforces time intervals between executions
   - Manages partial fills and remaining amounts

3. **Price Oracle**
   - Uses Uniswap V3 TWAP for reliable price feeds
   - Supports direct and WETH-quoted pairs
   - Handles decimal normalization

## Deployed Contracts

| Network       | Address                                    |
| ------------- | ------------------------------------------ |
| Monad Testnet | 0xa549F06eA5C42468f83d94cF8592eF2188439666 |

## Development

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- [Bun](https://bun.sh/) (for dependency management)

### Setup

```bash
# Clone the repository
git clone https://github.com/zuni-lab/dexon-contract
cd dexon-contract

# Install dependencies
bun install

# Copy and configure environment variables
cp .env.example .env
```

### Testing

```bash
# Run all tests
forge test

# Run with gas reporting
forge test --gas-report

# Run specific test
forge test --match-test testExecuteOrder

# Generate coverage report
bun run test:coverage
```

### Deployment

```bash
# Deploy to local network
forge script script/Deploy.s.sol --broadcast --fork-url http://localhost:8545

# Deploy to testnet (requires configured .env)
forge script script/Deploy.s.sol --broadcast --network sepolia
```

## Integration Guide

### Creating Orders

```typescript
const order = {
  account: userAddress,
  nonce: await dexon.nonces(userAddress),
  path: encodePath([WETH, USDC], [3000]),
  amount: parseEther("1"),
  triggerPrice: parseUnits("1800", 18), // $1800 per ETH
  slippage: 100, // 0.01%
  orderType: OrderType.LIMIT_ORDER,
  orderSide: OrderSide.SELL,
  deadline: Math.floor(Date.now() / 1000) + 3600,
};

const signature = await signOrder(order, signer);
```

### Creating TWAP Orders

```typescript
const twapOrder = {
  account: userAddress,
  nonce: await dexon.nonces(userAddress),
  path: encodePath([WETH, USDC], [3000]),
  amount: parseEther("10"),
  orderSide: OrderSide.SELL,
  interval: 3600, // 1 hour between executions
  totalOrders: 10, // Split into 10 parts
  startTimestamp: Math.floor(Date.now() / 1000),
};

const signature = await signTwapOrder(twapOrder, signer);
```

## Security

### Audits

- [Audit Report 1] - Date: TBD
- [Audit Report 2] - Date: TBD

### Security Considerations

- All orders require valid EIP-712 signatures
- Nonce-based replay protection
- Slippage protection on all trades
- Time-bound execution windows
- Partial fill support for TWAP orders

## Contributing

1. Fork the repository
2. Create your feature branch
3. Run tests and linting
4. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE.md](./LICENSE.md) file for details.
