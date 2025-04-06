// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/*
* @title OracleLib
* @author Zitife Otegbulu
* @notice This library is used to check the Chainlink Oracle for stale data
* If a price is stale, the function will revert, and render the DSCEngine unusable - this is by design
* We want the DSCEngine to freeze if prices become stable
*
* So if the Chainlink network explodes and you have a lot of money in your protocol... too bad
*
*/
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        if (updatedAt == 0 || updatedAt > block.timestamp) {
            revert OracleLib__StalePrice(); // Handle invalid updatedAt values
        }

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getTimeout() public pure returns (uint256) {
        return TIMEOUT;
    }
}
