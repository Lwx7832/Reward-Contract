//一键发币:https://coinjm.com/tokenmake/bep20-token-generator
//销毁 防机器人 营销 分红奖励 手续费添加流动池

// SPDX-License-Identifier: MIT

pragma solidity ^0.6.2;

import "./DividendPayingToken.sol";
import "./SafeMath.sol";
import "./IterableMapping.sol";
import "./Ownable.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router.sol";
import "./DividendTracker.sol";

contract Token is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public immutable uniswapV2Pair;
    bool private swapping;
    bool public swapEnabled = true;
    DividendTracker public dividendTracker;          //分红对象
    address public liquidityWallet;          //流动性钱包
    address private _marketingWalletAddress;         //营销钱包，收手续费的
    address public deadWallet = 0x000000000000000000000000000000000000dEaD;        //销毁钱包，也就是把钱打进这里。
    uint256 public maxSellTransactionAmount = 10000000000000 * (10 ** 16);              //最大卖出数量
    uint256 public swapTokensAtAmount = 1000000000 * (10 ** 18);                      
    uint256  BNBRewardsFee = 7;                                                     //分红每次交易百分之7的bnb
    uint256  liquidityFee = 3;                                                      //流动性手续费
    uint256  marketingFee = 4;                                                       //营销钱包收进的手续费

    uint256 public totalFees = BNBRewardsFee.add(liquidityFee).add(marketingFee);               //总手续费用
    uint256 public tradingEnabledTimestamp = 1628258400; //10:00pm                     //2021-08-06 22:00:00的时间戳          

    // sells have fees of 12 and 6 (10 * 1.2 and 5 * 1.2)           
    uint256 public immutable sellFeeIncreaseFactor = 120;

    // use by default 300,000 gas to process auto-claiming dividends
    //默认使用300000 gas 处理自动申请分红
    uint256 public gasForProcessing = 300000;

    mapping(address => bool) private _isExcludedFromFees;          //判断是否此账号需要手续费，true为不需要手续费
    mapping(address => bool) public automatedMarketMakerPairs;        //判断是否卖出
    mapping(address => bool) public _isBlacklisted;    //是否是黑名单,true表示这个地址是黑名单

    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);     //监听更新分红跟踪事件

    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);            //监听更新周边路由事件

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);

    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SendDividends(
        uint256 tokensSwapped,
        uint256 amount
    );

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    constructor(address _ma) public ERC20("man", "man") {

        dividendTracker = new DividendTracker();   

        liquidityWallet = owner();          //流动性钱包=msg.sender.也就是部署这个合约的钱包
        _marketingWalletAddress = _ma;          //营销钱包=_ma
        
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);  //构造测试网的_uniswapV2Router对象
        // Create a uniswap pair for this new token
        //为这个新币创建一个uniswap pair  也就是uniswap的核心合约
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())     //factory 返回地址也就是0x9Ac64那个
        .createPair(address(this), _uniswapV2Router.WETH());   //createPair创建交易对 .该函数接受任意两个代币地址为参数，用来创建一个新的交易对合约并返回新合约的地址。
        //createPair的第一个地址是这个合约的地址，第二个地址是0x9Ac64Cc6e地址
        uniswapV2Router = _uniswapV2Router;     
        uniswapV2Pair = _uniswapV2Pair;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // exclude from receiving dividends  不在分红范围内的
        dividendTracker.excludeFromDividends(address(dividendTracker));            
        dividendTracker.excludeFromDividends(address(this));                 //这个合约地址
        dividendTracker.excludeFromDividends(owner());                        //msg.sender地址,也就铸币接收者
        dividendTracker.excludeFromDividends(deadWallet);                     //销毁地址
        dividendTracker.excludeFromDividends(address(_uniswapV2Router));

        // exclude from paying fees or having max transaction amount 排除支付费用或拥有最大交易金额
        excludeFromFees(liquidityWallet, true);        //排除流动性钱包的支付手续费和最大交易金额
        excludeFromFees(address(this), true);              //排除铸币钱包的支付手续费和最大交易金额
        excludeFromFees(_marketingWalletAddress, true);      //排除营销钱包的支付手续费和最大交易金额

        _mint(owner(), 10000000000000 * (10 ** 18));            //铸币给msg.ssender于10000000000000个币；
    }                  
    //外部合约调用接收方法
    receive() external payable {

    }
    //改变最大卖出额度
    function changeMaxSellTransactionAmount(uint amount) external onlyOwner {
        maxSellTransactionAmount = amount;
    }
    //更新分红合约对象
    function updateDividendTracker(address newAddress) public onlyOwner {
        //如果新地址==adaddress(ddividendTracker)则跳出函数
        require(newAddress != address(dividendTracker), "RedCheCoin The dividend tracker already has that address");
        
        DividendTracker newDividendTracker = DividendTracker(payable(newAddress));

        require(newDividendTracker.owner() == address(this), "RedCheCoin The new dividend tracker must be owned by the RedCheCoin token contract");

        newDividendTracker.excludeFromDividends(address(newDividendTracker));       //newDividendTracker地址不分红
        newDividendTracker.excludeFromDividends(address(this));                    //这个合约地址不分红
        newDividendTracker.excludeFromDividends(owner());                           //msg.sender地址
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));          //代币对地址

        emit UpdateDividendTracker(newAddress, address(dividendTracker));   

        dividendTracker = newDividendTracker;                     
    }
    //更新周边路由事件
    function updateUniswapV2Router(address newAddress) public onlyOwner {
        require(newAddress != address(uniswapV2Router), "RedCheCoin The router already has that address");  //如果新的地址是原来的周边路由地址则跳出
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));         
        uniswapV2Router = IUniswapV2Router02(newAddress);      //把新的周边路由地址赋值给旧的
    }
    //排除手续费
    function excludeFromFees(address account, bool excluded) public onlyOwner {   //onlyOwner判断是不是msg.sender
        require(_isExcludedFromFees[account] != excluded, "RedCheCoin Account is already the value of 'excluded'");   //如果已经排除就跳出
        _isExcludedFromFees[account] = excluded;                 //设置是否排除的布尔值

        emit ExcludeFromFees(account, excluded);
    }
    //排除多个地址账号的手续费
    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }
    //设置lp流动性地址
    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2Pair, "RedCheCoin The PancakeSwap pair cannot be removed from automatedMarketMakerPairs");
        
        _setAutomatedMarketMakerPair(pair, value);
    }
    //设置黑名单地址
    function blacklistAddress(address account, bool value) external onlyOwner {
        _isBlacklisted[account] = value;   //如果是true就是黑名单
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        //做一个判断如果已经赋了布尔值就跳出函数
        require(automatedMarketMakerPairs[pair] != value, "RedCheCoin Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;     
        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    //更新流动池钱包
    function updateLiquidityWallet(address newLiquidityWallet) public onlyOwner {
        require(newLiquidityWallet != liquidityWallet, "RedCheCoin The liquidity wallet is already this address");
        _isExcludedFromFees[newLiquidityWallet] = true;          //设置新的流动池钱包
        emit LiquidityWalletUpdated(newLiquidityWallet, liquidityWallet);        
        liquidityWallet = newLiquidityWallet;          //旧流动池钱包=新流动池钱包             
    }
    //更新营销钱包
    function updateMarketingWallet(address newMarkting) public onlyOwner {
        require(newMarkting != _marketingWalletAddress, "RedCheCoin The Markting wallet is already this address");  //如果新营销钱包=旧营销钱包则跳出
        _isExcludedFromFees[newMarkting] = true;                                                    //设置新营销钱包除外手续费
        _marketingWalletAddress = newMarkting;                                                       //旧营销钱包=新营销钱包
    }
    //更新gas费用
    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue >= 200000 && newValue <= 500000, "RedCheCoin gasForProcessing must be between 200,000 and 500,000");    //非200000到500000则跳出
        require(newValue != gasForProcessing, "RedCheCoin Cannot update gasForProcessing to same value");       //如果和旧的值一样就跳出
        emit GasForProcessingUpdated(newValue, gasForProcessing);   
        gasForProcessing = newValue;                                      //旧的gas=新的gas
    }
    
    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns (uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }
    //block.timestamp (uint):当前块的时间戳
    //此函数通过到达开盘时间才能交易
    function getTradingIsEnabled() public view returns (bool) {
        return block.timestamp >= tradingEnabledTimestamp;
    }
    //返回是否除外手续费的布尔值
    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }
    //应该是取回分红？？？
    function withdrawableDividendOf(address account) public view returns (uint256) {
        return dividendTracker.withdrawableDividendOf(account);
    }
    //取的分红的地址
    function dividendTokenBalanceOf(address account) public view returns (uint256) {
        return dividendTracker.balanceOf(account);
    }
    
    function getAccountDividendsInfo(address account)
    external view returns (
        address,
        int256,
        int256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256) {
        return dividendTracker.getAccount(account);
    }

    function getAccountDividendsInfoAtIndex(uint256 index)
    external view returns (
        address,
        int256,
        int256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256) {
        return dividendTracker.getAccountAtIndex(index);
    }

    function processDividendTracker(uint256 gas) external {
        (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
        emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }

    function claim() external {
        dividendTracker.processAccount(msg.sender, false);
    }

    function getLastProcessedIndex() external view returns (uint256) {
        return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns (uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }
    //交易函数
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");    //如果发送方是空地址则跳出
        require(!_isBlacklisted[from], 'Blacklisted address');                        //如果接收方是空地址则跳出


        if (amount == 0) {                              //转0个币则直接转
            super._transfer(from, to, 0);
            return;
        }

        if (swapping) {
            super._transfer(from, to, amount);
            return;
        }

        bool isMng = _isExcludedFromFees[from] || _isExcludedFromFees[to];      //判断是否非手续费
        bool tradingIsEnabled = getTradingIsEnabled();               //判断是到开盘时间，true表示到了          

        // add liqiud
        if (!tradingIsEnabled) {                  //判断是否到开盘时间
            require(isMng, "This account cannot send tokens until trading is enabled");   //判断是否添加流动池账号，如果不是则跳出此函数
        }

        if (
            tradingIsEnabled &&
            balanceOf(uniswapV2Pair) > 0 &&
            automatedMarketMakerPairs[from] && 
            !isMng &&
            tradingIsEnabled &&                         
            block.timestamp <= tradingEnabledTimestamp + 9 seconds) {
            addBot(to);
        }

        if (
            !swapping &&                        
        from != address(uniswapV2Router) &&
        to != address(uniswapV2Router) &&
        !isMng
        ) {
            require(amount <= maxSellTransactionAmount, "Sell transfer amount exceeds the maxSellTransactionAmount.");  //判断是否超出最大可卖出数量
        }

        uint256 contractTokenBalance = balanceOf(address(this));          //获得该代币余额

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;        //是否可以交易

        if (
            swapEnabled &&
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            from != liquidityWallet &&
            to != liquidityWallet
        ) {
            swapping = true;

            uint256 marketingTokens = contractTokenBalance.mul(marketingFee).div(totalFees);    //营销钱包的币=该合约代币余额*营销手续费/总手续费
            swapAndSendToFee(marketingTokens);                                          //发送给营销钱包手续费用的币

            uint256 swapTokens = contractTokenBalance.mul(liquidityFee).div(totalFees);               //添加流动性的币=该合约代币余额*流动性手续费/总手续费
            swapAndLiquify(swapTokens);                                    //添加流动性

            uint256 sellTokens = balanceOf(address(this));                                //卖的币=该合约代币余额
            swapAndSendDividends(sellTokens);                                           //分红卖的币
            swapping = false;
        }


        bool takeFee = !swapping;                   

        // if any account belongs to _isExcludedFromFee account then remove the fee 如果任何帐户属于_isExcludedFromFee帐户，那么删除费用
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;                                   //设置无手续费
        }

        if (takeFee) {
            uint256 fees = amount.mul(totalFees).div(100);           //手续费=币数量*总手续费/100;

            // if sell, multiply by 1.2
            if (automatedMarketMakerPairs[to]) {
                fees = fees.mul(sellFeeIncreaseFactor).div(100);            //如果卖出的话手续费*1.2
            }

            amount = amount.sub(fees);             //币数量=币数量-手续费

            super._transfer(from, address(this), fees);            //转账msg.sender到合约地址，手续费用的币
        }

        super._transfer(from, to, amount);                  //转账实际已经扣除手续的币

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if (!swapping) {
            uint256 gas = gasForProcessing;       

            try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
            }
            catch {
            }
        }
    }
    //设置是否可交易
    function setSwapEnabled(bool _enabled) external onlyOwner {
        swapEnabled = _enabled;
    }
    //设置手续费用
    function setF(uint _BNBRewardsFee, uint _liquidityFee, uint _marketingFee) external onlyOwner {
        BNBRewardsFee = _BNBRewardsFee;
        liquidityFee = _liquidityFee;
        marketingFee = _marketingFee;
    }
    //添加黑名单的函数
    function addBot(address recipient) private {
        if (!_isBlacklisted[recipient]) _isBlacklisted[recipient] = true;
    }
    //发送给营销钱包手续费用
    function swapAndSendToFee(uint256 tokens) private {
        uint256 initialBNBBalance = address(this).balance;
        swapTokensForEth(tokens);   
        uint256 newBalance = address(this).balance.sub(initialBNBBalance);
        payable(_marketingWalletAddress).transfer(newBalance);
    }
    //交易流动性
    function swapAndLiquify(uint256 tokens) private {
        // split the contract balance into halves 把该合同余额平分，分成一半
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);

        // capture the contract's current ETH balance.   获取合同当前ETH余额。
        // this is so that we can capture exactly the amount of ETH that the   这样我们就能准确地捕获ETH的数量
        // swap creates, and not make the liquidity event include any ETH that    交换产生，而不使流动性事件包括任何ETH
        // has been manually sent to the contract    手动发送给合约地址
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH  ETH交换代币
        swapTokensForEth(half);
        // <- this breaks the ETH -> HATE swap when swap+liquify is triggered  当swap+liquify被触发时，这会打破ETH ->HATE swap

        // how much ETH did we just swap into?   我们刚才换了多少ETH ?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap      为uniswap增加流动性
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }
    //交换代币
    function swapTokensForEth(uint256 tokenAmount) private {


        // generate the uniswap pair path of token -> weth  生成unswap pair周边合约代币路径 -> 用eth位来表示
        address[] memory path = new address[](2);   
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);    

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );

    }
    //添加流动性
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        // approve token transfer to cover all possible scenarios      批准代币转账以覆盖所有可能的场景
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity           添加流动性
        uniswapV2Router.addLiquidityETH{value : ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable     //滑点是不可避免的
            0, // slippage is unavoidable   //滑点是不可避免的
            liquidityWallet,                     //流动性钱包;
            block.timestamp                  //当块的时间戳
        );

    }
    //交易分红
    function swapAndSendDividends(uint256 tokens) private {
        swapTokensForEth(tokens);
        uint256 dividends = address(this).balance;
        (bool success,) = address(dividendTracker).call{value : dividends}("");

        if (success) {
            emit SendDividends(tokens, dividends);
        }
    }
}
