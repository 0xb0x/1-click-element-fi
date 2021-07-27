
pragma solidity 0.7.0;
pragma experimental ABIEncoderV2;

import {IAsset, IVault} from "./balancer-core-v2/IVault.sol";
import "./element-finance/ITranche.sol";
import {PoolInterface} from "./interface/Swap.sol";
import { FlashLoanReceiverBase } from "./aave/FlashLoanReceiverBase.sol";
import { ILendingPool, ILendingPoolAddressesProvider} from "./aave/Interfaces.sol";
import { SafeERC20, SafeMath } from "./aave/Libraries.sol";



contract OneClick is FlashLoanReceiverBase {
    using SafeMath for uint256;

    IVault public immutable balVault;
    // IlendingPool public immutable lendingPool;
    address internal constant _ETH_CONSTANT = address(
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    );
    
    // /**
    //  * @param `_balVault` - address of custom balancer amm
    //  * @param `_addressProvider` -
    //  */ 
    constructor(address _balVault, ILendingPoolAddressesProvider _addressProvider) 
    FlashLoanReceiverBase(_addressProvider){
        balVault = IVault(_balVault);
        // lendingPool = IlendingPool(lendingPoolAddr);
    }


    // /**
    //  * @param `poolId` - id of balancer pool to use for principal token swap
    //  * @param `amount` - 
    //  * @param `trancheAddr` - 
    //  * @param `from` - token deposited by msg.sender
    //  * @param `swap_bPool` - address of balancer pool to use for token swap
    //  */
    function decollaterize(
        bytes32 poolId,
        uint256 amount,
        address trancheAddr,
        address from,
        address swap_bPool
    ) public {

        ITranche tranche = ITranche(trancheAddr);
        // from == _ETH_CONSTANT ? weth.deposit{ value: amount }(); : pass ;    
        uint amtIn = swap(from, address(tranche.underlying()) , amount, swap_bPool);
        (uint256 pt, ) = mint(amtIn, tranche);
        uint tokenRecieved = swapPTsForBaseTokenOnBalancer(
            trancheAddr,
            poolId, 
            address(tranche.underlying()), 
            address(this), 
            msg.sender, 
            pt
        );
        uint amtOut = swap(address(tranche.underlying()), from , tokenRecieved, swap_bPool);
        if (from == _ETH_CONSTANT){
            (bool success, ) = msg.sender.call{value: amtOut}("");
            require(success);
        }else{
            IERC20(from).transferFrom(address(this), msg.sender, amtOut);
        }
    }

    function decollaterizeEth(bytes32 poolId, address trancheAddr, address swap_bPool) external payable {
        uint amount = msg.value;
        require(amount > 0);
        decollaterize(poolId, amount, trancheAddr, _ETH_CONSTANT, swap_bPool);
    }

    function mint(uint256 amt, ITranche tranche) internal returns(uint256, uint256){
        address wrappedPositionAddr = address(uint160(address(tranche.position())));
        tranche.underlying().transferFrom(msg.sender, wrappedPositionAddr, amt);
        (uint256 pt, uint256 yt) = tranche.prefundedDeposit(address(this));
        return(pt, yt);
    }

    function swapPTsForBaseTokenOnBalancer(
        address _trancheAddress,
        bytes32 _poolId,
        address _baseTokenAddress,
        address _fromAddress,
        address payable _receiverAddress,
        uint256 _amount
    ) public returns (uint256) {
        // Swap PTs (tranche contract token) for base tokens
        IVault.SwapKind kind = IVault.SwapKind.GIVEN_IN;
        IAsset assetIn = IAsset(_trancheAddress);
        IAsset assetOut = IAsset(_baseTokenAddress);
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap({
            poolId: _poolId,
            kind: kind,
            assetIn: assetIn,
            assetOut: assetOut,
            amount: _amount,
            userData: bytes("")
        });

        // Sell from this contract to Wrapped Position contract /userAddress (for last compounding)
        IVault.FundManagement memory funds = IVault.FundManagement({
            sender: _fromAddress,
            fromInternalBalance: false,
            recipient: _receiverAddress,
            toInternalBalance: false
        });

        uint256 limit = 0;
        uint256 deadline = type(uint).max; 

        uint256 baseTokensReceived = balVault.swap(
            singleSwap,
            funds,
            limit,
            deadline
        );
        return baseTokensReceived;
    }

    function swap(address from, address to, uint256 amt, address bPool) internal returns(uint){
        (uint tokenAmountOut, ) = PoolInterface(bPool).swapExactAmountIn(
            from,
            amt, // maxAmountIn, set to max -> use all sent ETH
            to,
            0,
            type(uint).max // maxPrice, set to max -> accept any swap prices
        );
        return tokenAmountOut;
    }

    

    function yTCWithFlashloan(
        uint256 amount,
        uint256 mode,
        bytes32 poolId,
        address trancheAddr,
        uint n
    ) external {
        ITranche tranche = ITranche(trancheAddr);

        address receiverAddress = address(this);

        address[] memory assets = new address[](1);
        assets[0] = address(tranche.underlying()); // Eth

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](1);
        modes[0] = mode;

        address onBehalfOf = msg.sender;
        bytes memory params = abi.encode(n, poolId, tranche);
        uint16 referralCode = 0;


        _lendingPool.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
        
    }
 

    /**
        This function is called after your contract has received the flash loaned amount
     */

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    )
        external
        override
        returns (bool)
    {
        uint256 amount = amounts[0];
        uint256 premium = premiums[0];
        address asset = assets[0];

        (uint256 n, bytes32 poolId, ITranche tranche) = abi.decode(params, (uint256, bytes32, ITranche));

        address payable wrappedPositionAddress = address(uint160(address(tranche.position())));
        tranche.underlying().transferFrom(msg.sender, wrappedPositionAddress, amount);
        (uint finalTokenRecieved) = yTCompound(n, tranche, poolId, wrappedPositionAddress);

        uint totalAmtToPay = amount.add(premium); 
        IERC20(asset).transferFrom(msg.sender, address(this), totalAmtToPay.sub(finalTokenRecieved));
        IERC20(asset).approve(address(_lendingPool), totalAmtToPay);
        return true;
        
    }

    function yTCompound(uint n, ITranche tranche, bytes32 poolId, address payable wrappedPositionAddress) internal returns(uint){
        uint ytBal = 0;
        uint finalTokenRecieved;
        for(uint i = 0; i < n; i++){
            (uint256 pt, uint256 yt) = tranche.prefundedDeposit(address(this));
            ytBal += yt;
            uint tokenRecieved = swapPTsForBaseTokenOnBalancer(
                address(tranche),
                poolId, 
                address(tranche.underlying()), 
                address(this), 
                wrappedPositionAddress,
                pt
            );
            finalTokenRecieved = tokenRecieved;
        }
        tranche.interestToken().transfer(msg.sender, ytBal);
        return finalTokenRecieved ;
    }

}