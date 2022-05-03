// SPDX-License-Identifier: MIT

//// _____.___.__       .__       ._____      __      .__   _____  ////
//// \__  |   |__| ____ |  |    __| _/  \    /  \____ |  |_/ ____\ ////
////  /   |   |  |/ __ \|  |   / __ |\   \/\/   /  _ \|  |\   __\  ////
////  \____   |  \  ___/|  |__/ /_/ | \        (  <_> )  |_|  |    ////
////  / ______|__|\___  >____/\____ |  \__/\  / \____/|____/__|    ////
////  \/              \/           \/       \/                     ////

pragma solidity 0.8.9;

import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import './interfaces/IRouteResolver.sol';
import './interfaces/IRouteOracle.sol';

contract RouteOracle is OwnableUpgradeable, IRouteOracle {
    struct Route {
        IRouteResolver resolver;
        bytes data;
        address nextToken;
    }

    event SetRoute(address tokenFrom, address tokenTo);
    event SetOperator(address addr, bool isOperator);

    mapping(address => mapping(address => Route)) public routes;

    mapping(address => bool) public operators;

    modifier onlyOperator() {
        require(operators[msg.sender], 'onlyOperator: caller is not an operator');
        _;
    }

    function initialize() external initializer {
        operators[msg.sender] = true;
        __Ownable_init();
    }

    function setRoute(
        address _tokenFrom,
        address _tokenTo,
        Route[] calldata _routes
    ) external onlyOperator {
        require(_routes.length <= 5, 'setRoute: too many routes');
        address lastTokenFrom = _tokenFrom;
        for (uint256 i; i < _routes.length; i++) {
            Route calldata route = _routes[i];
            require(route.nextToken != _tokenTo, 'setRoute: invalid route');
            address routeTokenTo = route.nextToken != address(0) ? route.nextToken : _tokenTo;
            route.resolver.validateData(lastTokenFrom, routeTokenTo, route.data);
            routes[lastTokenFrom][_tokenTo] = route;
            emit SetRoute(lastTokenFrom, _tokenTo);
            lastTokenFrom = route.nextToken;
        }
    }

    function resolveSwapExactTokensForTokens(
        uint256 _amountIn,
        address _tokenFrom,
        address _tokenTo,
        address _recipient
    )
        external
        view
        returns (
            address router,
            address nextToken,
            bytes memory sig
        )
    {
        Route memory route = routes[_tokenFrom][_tokenTo];
        (router, sig) = IRouteResolver(route.resolver).resolveSwapExactTokensForTokens(
            _amountIn,
            route.data,
            _recipient
        );
        nextToken = route.nextToken;
    }

    function getAmountOut(
        uint256 _amountIn,
        address _tokenFrom,
        address _tokenTo
    ) public view returns (uint256) {
        Route memory route = routes[_tokenFrom][_tokenTo];
        uint256 amountOut = IRouteResolver(route.resolver).getAmountOut(_amountIn, route.data);
        if (route.nextToken != address(0)) {
            return getAmountOut(amountOut, route.nextToken, _tokenTo);
        }
        return amountOut;
    }

    /**
     * @notice adds or removes an operator
     * @dev can only be called by the owner
     * @param _addr address of the operator
     * @param _isOperator whether the given address will be set as an operator
     */
    function setOperator(address _addr, bool _isOperator) external onlyOwner {
        operators[_addr] = _isOperator;
        emit SetOperator(_addr, _isOperator);
    }
}
