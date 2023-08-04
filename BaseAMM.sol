// SPDX-License-Identifier: MIT

import "./lptoken.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IAMM.sol";
import "./StableAlgorithm.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

pragma solidity ^0.8.9;

contract AnchorFinance is AccessControl{


    bytes32 public constant FEE_CONTROL_ROLE = keccak256("FEE_CONTROL_ROLE");
    bytes32 public constant PAIR_CONTROL_ROLE = keccak256("PAIR_CONTROL_ROLE");
    uint constant ONE_ETH = 10 ** 18;


    mapping(address => address) pairCreator;//lpAddr pairCreator
    address [] _lpTokenAddressList;//lptoken的数组
    mapping(address => mapping(address => uint)) reserve;//第一个address是lptoken的address ，第2个是相应token的资产，uint是资产的amount
    uint lpFee;//fee to pool
    uint fundFee;
    //检索lptoken
    mapping(address => mapping(address => address)) public findLpToken;
    IWETH  WETH;
    address  WETHAddr;
    //mapping (address => bool) public isStablePair;
    mapping (address => address[2]) _lpInfo;
    mapping (address => bool) _lpSwapStatic;
    mapping (address => uint) _lpProfit;
    mapping (address => uint) _lpCreatedTime;
    mapping (address => mapping (address => bool)) _userLpExist;
    mapping (address => address[]) _userLpTokenList;



    address fundAddr;




    constructor(address _wethAddr) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FEE_CONTROL_ROLE, msg.sender);
        _grantRole(PAIR_CONTROL_ROLE, msg.sender);
        setWeth(_wethAddr);
    }

    receive() payable external {}

    modifier reEntrancyMutex() {
        bool _reEntrancyMutex;

        require(!_reEntrancyMutex,"FUCK");
        _reEntrancyMutex = true;
        _;
        _reEntrancyMutex = false;

    }





//管理人员权限

    function setLpFee(uint fee) external onlyRole(FEE_CONTROL_ROLE){
        lpFee = fee;// dx / 100000
    }



    function setFundFee(uint fee)external onlyRole(FEE_CONTROL_ROLE){
        fundFee = fee;
    }

    function setFundAddr(address _fundAddr) external onlyRole(FEE_CONTROL_ROLE){
        fundAddr = _fundAddr;
    }



    function setWeth(address _wethAddr) public onlyRole(PAIR_CONTROL_ROLE){
        WETH = IWETH(_wethAddr);
        WETHAddr = _wethAddr;
    }
    function setLpSwapStatic(address _lpAddr, bool _static) external onlyRole(PAIR_CONTROL_ROLE){
        _lpSwapStatic[_lpAddr] = _static;
    }

//业务合约
    //添加流动性

    function addLiquidityWithETH(address _token, uint _tokenAmount) public payable reEntrancyMutex
    {
        uint ETHAmount = msg.value;
        address user = msg.sender;
       // address addr = address(this);
        WETH.depositETH{value : ETHAmount}();
        //WETH.approve(user,ETHAmount);
        WETH.transfer(user,ETHAmount);
        addLiquidity(WETHAddr,_token, ETHAmount,_tokenAmount);

    }



    function addLiquidity(address _token0, address _token1, uint _amount0,uint _amount1) public returns (uint shares) {
        
        LPToken lptoken;//lptoken接口，为了mint 和 burn lptoken
        
        require(_amount0 > 0 ,"require _amount0 > 0 && _amount1 >0");
        require(_token0 != _token1, "_token0 == _token1");
        IERC20 token0 = IERC20(_token0);
        IERC20 token1 = IERC20(_token1);
        
        //token1.transferFrom(msg.sender, address(this), _amount1);
        address lptokenAddr;

        /*
        How much dx, dy to add?
        xy = k
        (x + dx)(y + dy) = k'
        No price change, before and after adding liquidity
        x / y = (x + dx) / (y + dy)
        x(y + dy) = y(x + dx)
        x * dy = y * dx
        x / y = dx / dy
        dy = y / x * dx
        */
        //问题：
        /*
        如果项目方撤出所有流动性后会存在问题
        1.添加流动性按照比例 0/0 会报错

        解决方案：
        每次添加至少n个token
        且remove流动性至少保留n给在amm里面

        */


        if (findLpToken[_token1][_token0] == address(0)) {
            //当lptoken = 0时，创建lptoken
            shares = StableAlgorithm._sqrt(_amount0 * _amount1);

            createPair(_token0,_token1);

            lptokenAddr = findLpToken[_token1][_token0];
            lptoken = LPToken(lptokenAddr);//获取lptoken地址
            pairCreator[lptokenAddr] = msg.sender;

            token0.transferFrom(msg.sender, address(this), _amount0);
            token1.transferFrom(msg.sender, address(this), _amount1);

            
        } else {
            lptokenAddr = findLpToken[_token1][_token0];
            lptoken = LPToken(lptokenAddr);//获取lptoken地址
            shares = StableAlgorithm._min(
                (_amount0 * lptoken.totalSupply()) / reserve[lptokenAddr][_token0],
                (_amount1 * lptoken.totalSupply()) / reserve[lptokenAddr][_token1]
            );
            _amount1 = reserve[lptokenAddr][_token1] * _amount0 / reserve[lptokenAddr][_token0];
            token0.transferFrom(msg.sender, address(this), _amount0);
            token1.transferFrom(msg.sender, address(this), _amount1);
            //获取lptoken地址
        }
        require(shares > 0, "shares = 0");
        lptoken.mint(msg.sender,shares);
        if(!_userLpExist[msg.sender][lptokenAddr])
        {
            _userLpTokenList[msg.sender].push(lptokenAddr);
            _userLpExist[msg.sender][lptokenAddr] = true;

        }
        

        _update(lptokenAddr,_token0, _token1, reserve[lptokenAddr][_token0] + _amount0, reserve[lptokenAddr][_token1] + _amount1);
    }










    function removeLiquidity(
        address _token0,
        address _token1,
        uint _shares
    ) public  returns (uint amount0, uint amount1) {
        LPToken lptoken;//lptoken接口，为了mint 和 burn lptoken
        IERC20 token0 = IERC20(_token0);
        IERC20 token1 = IERC20(_token1);
        address lptokenAddr = findLpToken[_token0][_token1];

        lptoken = LPToken(lptokenAddr);

        if(pairCreator[lptokenAddr] == msg.sender)
        {
            require(lptoken.balanceOf(msg.sender) - _shares > 100 ,"paieCreator should left 100 wei lptoken in pool");
        }

        amount0 = (_shares * reserve[lptokenAddr][_token0]) / lptoken.totalSupply();//share * totalsuply/bal0
        amount1 = (_shares * reserve[lptokenAddr][_token1]) / lptoken.totalSupply();
        require(amount0 > 0 && amount1 > 0, "amount0 or amount1 = 0");

        lptoken.burn(msg.sender, _shares);
        _update(lptokenAddr,_token0, _token1, reserve[lptokenAddr][_token0] - amount0, reserve[lptokenAddr][_token1] - amount1);
        

        token0.transfer(msg.sender, amount0);
        token1.transfer(msg.sender, amount1);
    }

    //交易

    function swapWithETH(address _tokenOut,uint _disirSli) public payable reEntrancyMutex
    {
        uint amountIn = msg.value;
        //WETH.depositETH{value : amountIn}();
        WETH.depositETHFor{value : amountIn}(msg.sender);
        //WETH.transfer(msg.sender, amountIn);
        swapByLimitSli(WETHAddr,_tokenOut,amountIn, _disirSli);

    }



    function swapToETH(address _tokenIn, uint _amountIn, uint _disirSli)public {
        //IERC20 tokenIn = IERC20(_tokenIn);
        //tokenIn.transferFrom(msg.sender, address(this), _amountIn);

        uint amountOut = swapByLimitSli2(_tokenIn,WETHAddr,_amountIn, _disirSli);
        WETH.withdrawETH(amountOut);
        address payable user = payable(msg.sender);
        user.transfer(amountOut);

    }






    function swapByPath(uint _amountIn, uint _disirSli,address [] memory _path) public {
        uint amountIn = _amountIn;
        for(uint i; i < _path.length - 1; i ++ ){
            (address tokenIn,address tokenOut) = (_path[i],_path[i + 1]);
            amountIn = swapByLimitSli(tokenIn, tokenOut, amountIn, _disirSli);
        }
    }

    function swapByLimitSli(address _tokenIn, address _tokenOut, uint _amountIn, uint _disirSli) public returns(uint amountOut){
        require(
            findLpToken[_tokenIn][_tokenOut] != address(0),
            "invalid token"
        );
        require(_amountIn > 0, "amount in = 0");
        require(_tokenIn != _tokenOut);
        //require(_amountIn >= 1000, "require amountIn >= 1000 wei token");

        IERC20 tokenIn = IERC20(_tokenIn);
        IERC20 tokenOut = IERC20(_tokenOut);
        address lptokenAddr = findLpToken[_tokenIn][_tokenOut];
        uint reserveIn = reserve[lptokenAddr][_tokenIn];
        uint reserveOut = reserve[lptokenAddr][_tokenOut];

        tokenIn.transferFrom(msg.sender, address(this), _amountIn);


        //交易税收 
        uint amountInWithFee = (_amountIn * (100000-lpFee-fundFee)) / 100000;
        if(getFundFee() > 0){
            tokenIn.transfer(fundAddr,fundFee * _amountIn / 100000);
        }
        amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);

        //检查滑点
        setSli(amountInWithFee,reserveIn,reserveOut,_disirSli);


        tokenOut.transfer(msg.sender, amountOut);
        uint totalReserve0 = reserve[lptokenAddr][_tokenIn] + _amountIn; 
        uint totalReserve1 = reserve[lptokenAddr][_tokenOut] - amountOut;

        uint profit = lpFee * _amountIn / 100000;

        _lpProfit[lptokenAddr] += profit;

        _update(lptokenAddr,_tokenIn, _tokenOut, totalReserve0, totalReserve1);

    }


    function swapByLimitSli2(address _tokenIn, address _tokenOut, uint _amountIn, uint _disirSli) public returns(uint amountOut){
        require(
            findLpToken[_tokenIn][_tokenOut] != address(0),
            "invalid token"
        );
        require(_amountIn > 0, "amount in = 0");
        require(_tokenIn != _tokenOut);
        //require(_amountIn >= 1000, "require amountIn >= 1000 wei token");

        IERC20 tokenIn = IERC20(_tokenIn);
        //IERC20 tokenOut = IERC20(_tokenOut);
        address lptokenAddr = findLpToken[_tokenIn][_tokenOut];
        uint reserveIn = reserve[lptokenAddr][_tokenIn];
        uint reserveOut = reserve[lptokenAddr][_tokenOut];

        tokenIn.transferFrom(msg.sender, address(this), _amountIn);


        //交易税收 
        uint amountInWithFee = (_amountIn * (100000-lpFee-fundFee)) / 100000;
        if(getFundFee() > 0){
            tokenIn.transfer(fundAddr,fundFee * _amountIn / 100000);
        }
        amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);

        //检查滑点
        setSli(amountInWithFee,reserveIn,reserveOut,_disirSli);


        //tokenOut.transfer(msg.sender, amountOut);
        uint totalReserve0 = reserve[lptokenAddr][_tokenIn] + _amountIn; 
        uint totalReserve1 = reserve[lptokenAddr][_tokenOut] - amountOut;

        uint profit = lpFee * _amountIn / 100000;

        _lpProfit[lptokenAddr] += profit;

        _update(lptokenAddr,_tokenIn, _tokenOut, totalReserve0, totalReserve1);

    }








    //暴露数据查询方法

    function getReserve(address _lpTokenAddr, address _tokenAddr) public view returns(uint)
    {
        return reserve[_lpTokenAddr][_tokenAddr];
    }

    function getLpFee()public view returns(uint) {
        return lpFee;
        
    }


    function getFundFee()public view returns(uint) {
        return fundFee;
    }

    function getLptoken(address _tokenA, address _tokenB) public view returns(address)
    {
        return findLpToken[_tokenA][_tokenB];
    }





    function getLpTokenLength() public view returns(uint)
    {
        return _lpTokenAddressList.length;
    }



    function getLpTokenList(uint _index)public view returns(address){
        return _lpTokenAddressList[_index];
    }



    function getUserLpTokenList(address _userAddr) public view returns(address [] memory){
        return _userLpTokenList[_userAddr];
    }


//依赖方法
    //creatpair

    function createPair(address addrToken0, address addrToken1) internal returns(address){
        bytes32 _salt = keccak256(
            abi.encodePacked(
                addrToken0,addrToken1
            )
        );

        address lptokenAddr = address(new LPToken{
            salt : bytes32(_salt)
        }
        ());

         //检索lptoken
        _lpTokenAddressList.push(lptokenAddr);
        findLpToken[addrToken0][addrToken1] = lptokenAddr;
        findLpToken[addrToken1][addrToken0] = lptokenAddr;

        _lpInfo[lptokenAddr] = [addrToken0,addrToken1];

        return lptokenAddr;
    }



    function getBytecode() internal pure returns(bytes memory) {
        bytes memory bytecode = type(LPToken).creationCode;
        return bytecode;
    }

    function getAddress(bytes memory bytecode, bytes32 _salt)
        internal
        view
        returns(address)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(this), _salt, keccak256(bytecode)
            )
        );

        return address(uint160(uint(hash)));
    }


    function lpInfo(address _lpAddr) public view returns(address [2] memory){
        return _lpInfo[_lpAddr];
    }

    function getLpSwapStatic(address _lpAddr) public view returns(bool){
        return _lpSwapStatic[_lpAddr];
    }

    function getLpProfit(address _lpAddr) public view returns(uint){
        return _lpProfit[_lpAddr];
    }

    function getLpCreatedTime(address _lpAddr) public view returns(uint) {
        return _lpCreatedTime[_lpAddr];
        
    }

    //数据更新

    function _update(address lptokenAddr,address _token0, address _token1, uint _reserve0, uint _reserve1) private {
        reserve[lptokenAddr][_token0] = _reserve0;
        reserve[lptokenAddr][_token1] = _reserve1;
    }

//数学库





    function setSli(uint dx, uint x, uint y, uint _disirSli) private pure returns(uint){


        uint amountOut = (y * dx) / (x + dx);

        uint dy = dx * y/x;
        /*
        loseAmount = Idea - ammOut
        Sli = loseAmount/Idea
        Sli = [dx*y/x - y*dx/(dx + x)]/dx*y/x
        */
        uint loseAmount = dy - amountOut;

        uint Sli = loseAmount * 10000 /dy;
        
        require(Sli <= _disirSli, "Sli too large");
        return Sli;

    }










}
