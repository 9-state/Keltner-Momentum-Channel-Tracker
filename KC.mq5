//+------------------------------------------------------------------+
//| Script program st//+------------------------------------------------------------------+
//|                                 Keltner Momentum Channel Tracker |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "9state & XHL"
#property link      "https://github.com/9-state/Keltner-Momentum-Channel-Tracker"
#property version   "1.31"
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Arrays\ArrayDouble.mqh>  
#include <Trade\AccountInfo.mqh>

input int      KC_PERIOD = 20;        // 凯尔特纳通道周期
//input int      ATR_PERIOD = 24;       // ATR计算周期
//input int      CHANDELIER_PERIOD = 24;// 吊灯止损周期
//input double   CHANDELIER_MULTIPLIER = 3.0; // 吊灯止损乘数
input bool     ActivateTrend = true; // 开启趋势过滤
input int      FastMA_Period = 5; // 短线MA周期
input int      SlowMA_Period = 10; // 长线MA周期
input int      MAGIC_NUMBER = 200055;  // EA魔术码
input double   MAX_POSITION_PCT = 0.05; // 最大仓位比例
input int      TradingStartHour = 5;    // 开始交易小时(GMT)
input int      TradingEndHour = 20;      // 结束交易小时(GMT)
input double   TestCapital = 100000;    // 试验资金额度(USD)
input bool     EnableCapitalLimit = true;// 启用资金限制

int            fastmaHandle;              // fast移动平均线句柄
int            slowmaHandle;              // slow移动平均线句柄
int            atrHandle;             // ATR指标句柄
int            highHandle;            // 最高价句柄(用于吊灯止损)
int            lowHandle;             // 最低价句柄(用于吊灯止损)
double         maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
double         virtualBalance = TestCapital; // 虚拟余额
double         usedMargin = 0;               // 已用保证金
double         floatingProfit = 0;           // 浮动盈亏

static datetime lastBarTime = 0;
static double lastBias = 0, lastATR = 0, lastMedian = 0, lastM = 1.0;
static double upper_current = 0, lower_current = 0,upper_last = 0, lower_last = 0, ma_current = 0;

CTrade trade;
CPositionInfo positionInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 初始化交易对象
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   trade.SetMarginMode();
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   //--- 初始化指标句柄
   fastmaHandle = iMA(_Symbol, _Period, FastMA_Period, 0, MODE_SMA, PRICE_WEIGHTED);
   slowmaHandle = iMA(_Symbol, _Period, SlowMA_Period, 0, MODE_SMA, PRICE_WEIGHTED);
   //atrHandle = iATR(_Symbol, _Period, ATR_PERIOD);
   
   if(/*atrHandle == INVALID_HANDLE || */fastmaHandle == INVALID_HANDLE || slowmaHandle == INVALID_HANDLE)
   {
      Print("指标初始化失败!");
      return(INIT_FAILED);
   }
   
   //--- 检查最少K线数量
   if(Bars(_Symbol, _Period) < KC_PERIOD/* + ATR_PERIOD*/)
   {
      Print("Not enough bars for calculation");
      return(INIT_FAILED);
   }
   
   Print("Expert initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- 释放指标句柄
   if(fastmaHandle != INVALID_HANDLE) IndicatorRelease(fastmaHandle);
   if(slowmaHandle != INVALID_HANDLE) IndicatorRelease(slowmaHandle);
   //if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   
   Print("Expert deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{  
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   lastBarTime = currentBarTime;

   // 基础检查
   if(!IsTradingAllowed()) return;
   if(!RiskCheck()) return;    
   
   //如果新的K线已经到来
   if(isNewBar)
   {
      if(EnableCapitalLimit)
      {
         // 计算当前虚拟账户状态
         UpdateVirtualAccount();
        
         // 检查资金是否充足
         if(virtualBalance <= 0)
         {
            Comment("试验资金已耗尽！");
            return;
         }
     }
   
   
      // 强制刷新仓位数据
      PositionsTotal(); // 重要！确保数据最新
      
      // 吊灯止损管理
      //ManageChandelierExit();
      
      //获取TrendSignal
      int trendDirection = CheckMATrend();
      
      // 获取KCSignal
      int signal = GetTradingSignal();
      if(signal == 0) return; // 无信号不执行
      
      if(ActivateTrend)
      {
         if(signal == 1 && trendDirection == 1)  signal = 1;  // 只做顺势多
         if(signal == -1 && trendDirection == -1) signal = -1;// 只做顺势空
         if(signal + trendDirection == 0) signal = 0;
      }
  
      // 仓位状态检查
      bool hasLong = false, hasShort = false;
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {  

         if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER) continue;
         
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(posType == POSITION_TYPE_BUY)
         {
            hasLong = true;
         }
         else if(posType == POSITION_TYPE_SELL)
         {
            hasShort = true;
         }
      }
      
      // 交易执行
      if(signal == 1)
      {
         if(hasShort) CloseSymbolPositions(_Symbol);
         EnterLong();
      }
      else if(signal == -1)
      {
         if(hasLong) CloseSymbolPositions(_Symbol);
         EnterShort();
      }
    }
}

//+------------------------------------------------------------------+
//| 检查是否允许交易                                                    |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   // 检查交易时段
   MqlDateTime timeNow;
   TimeCurrent(timeNow);
   if(timeNow.hour < TradingStartHour || timeNow.hour >= TradingEndHour)
      return false;
   
   // 检查账户状态
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
      Print("终端禁止交易");
      return false;
   }
   
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) {
      Print("账户禁止EA交易");
      return false;
   }
   
   // 检查品种交易状态
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL) {
      Print(_Symbol, " 禁止交易");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| 风险控制检查                                                       |
//+------------------------------------------------------------------+
bool RiskCheck()
{
   static datetime lastCheckTime = 0;
   
   // 每5分钟检查一次（避免频繁触发）,未到检查间隔时直接返回true（允许继续交易）
   if(TimeCurrent() - lastCheckTime < 300) return true;
   lastCheckTime = TimeCurrent();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // 更新maxEquity（只在增长时更新）
   if(equity > maxEquity) {
      maxEquity = equity;
      Print("更新最大权益值:", maxEquity);
   }
   
   // 检查回撤（添加容差0.5%防止波动误判）
   if(maxEquity > 0 && (maxEquity - equity) / maxEquity > 0.105) {
      PrintFormat("触发回撤限制(10.5%%) 当前回撤:%.2f%%, 强平所有仓位", 
                 (maxEquity - equity)/maxEquity*100);
      
      EmergencyCloseAll();
      maxEquity = equity * 0.95; // 重置为当前值的95%，避免立即重复触发
      return false;
   }
   
   return true;
}
//+------------------------------------------------------------------+
//| 进入多头仓位                                                     |
//+------------------------------------------------------------------+
void EnterLong()
{  
   MqlTick last_tick;
   if(!SymbolInfoTick(_Symbol, last_tick)) return;
   
   // 计算仓位大小
   double price = last_tick.ask;
   double volume = CalculateProperVolume();
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   // 发送买入订单
   trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, volume, price, 0, 0, "KC策略多头入场");
   //Print("freeMargin = ", freeMargin);
}

//+------------------------------------------------------------------+
//| 进入空头仓位                                                     |
//+------------------------------------------------------------------+
void EnterShort()
{
   MqlTick last_tick;
   if(!SymbolInfoTick(_Symbol, last_tick)) return;
   
   // 计算仓位大小
   double price = last_tick.bid;
   double volume = CalculateProperVolume();
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   // 发送卖出订单
   trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, volume, price, 0, 0, "KC策略空头入场");
   //Print("freeMargin = ", freeMargin);
}

//+------------------------------------------------------------------+
//| 获取交易信号                                                    |
//+------------------------------------------------------------------+
int GetTradingSignal()
{   
         // 1. 获取4k-2个收盘价数据
         double rates[];
         CopyClose(_Symbol, _Period, 1, KC_PERIOD*4-2, rates);
         ArrayReverse(rates); // 反转数组，使最新数据在[0]

         // 计算MA序列 (3k-1个数据)
         double ma[];
         ArrayResize(ma, KC_PERIOD*3-1);
         for(int i = 0; i < ArraySize(ma); i++) {
             double sum = 0.0;
             for(int j = i; j < i + KC_PERIOD; j++) {
                 sum += rates[j];
             }
             ma[i] = sum / KC_PERIOD;
         }
         
         // 获取3k-1个收盘价数据
         double closes[];
         CopyClose(_Symbol, _Period, 1, KC_PERIOD*3-1, closes);
         ArrayReverse(closes); // 反转数组
         
         // 计算bias序列 (3k-1个数据)
         double bias[];
         ArrayResize(bias, KC_PERIOD*3-1);
         for(int i=0; i<ArraySize(bias); i++) {
             bias[i] = (closes[i] / ma[i]) - 1;
         }
         
         // 计算median序列 (2k个数据)
         double alpha = 2.0 / (KC_PERIOD + 1);
         double median[];
         ArrayResize(median, KC_PERIOD*2);
         
         for(int i = 0; i < ArraySize(median); i++) {
             // 1. 计算窗口内的SMA
             double sum = 0.0;
             int window_start = i;
             int window_end = i + KC_PERIOD - 1;
             
             // 边界检查
             if(window_end >= ArraySize(bias)) {
                 Print("Error: Not enough bias data for window ", i);
                 break;
             }
             
             for(int j = window_start; j <= window_end; j++) {
                 sum += bias[j];
             }
             double sma = sum / KC_PERIOD;
         
             // 2. 独立作用域的EWMA计算
             double current_ewma = sma;
             for(int j = window_start; j <= window_end; j++) {
                 current_ewma = alpha * bias[j] + (1 - alpha) * current_ewma;
             }
             
             median[i] = current_ewma;
         }
         
         // 计算TR序列 (2k个数据)
         double tr[];
         ArrayResize(tr, KC_PERIOD*2);
         
         for(int i = 0; i < ArraySize(tr); i++) {
             double maxVal = bias[i];
             double minVal = bias[i];
             
             for(int j = i + 1; j < i + KC_PERIOD; j++) {
                 if(bias[j] > maxVal) maxVal = bias[j];
                 if(bias[j] < minVal) minVal = bias[j];
             }
             tr[i] = MathMax(maxVal - minVal, 1e-6);
         }
         
         // 计算ATR序列 (k+1个数据)
         double atr[];
         ArrayResize(atr, KC_PERIOD+1);
         
         for(int i=0; i<ArraySize(atr); i++) {
             double sum = 0.0;
             for(int j=i; j<i+KC_PERIOD; j++) {
                 sum += tr[j];
             }
             atr[i] = sum / KC_PERIOD;
         }
         
         // 计算z_score序列 (k+1个数据)
         double z_score[];
         ArrayResize(z_score, KC_PERIOD+1);
         
         for(int i=0; i<ArraySize(z_score); i++) {
             // 因为数组已反转，最新数据在[0]，所以直接对应位置计算
             if(atr[i] > 1e-6) {
                 z_score[i] = MathAbs(bias[i] - median[i]) / atr[i];
             } else {
                 z_score[i] = 0;
             }
         }
         
         // 计算m_current和m_last
         double m_current = -DBL_MAX;
         for(int i=0; i<KC_PERIOD; i++) {
             if(z_score[i] > m_current) m_current = z_score[i];
         }
         
         double m_last = -DBL_MAX;
         for(int i=1; i<=KC_PERIOD; i++) {
             if(z_score[i] > m_last) m_last = z_score[i];
         }
         
         // 计算当前MA值
         ma_current = ma[0]; // 最新MA值
         lastBias = bias[1];  // 上一个bias值
         
         // 计算上下轨
         upper_current = median[0] + atr[0] * m_current;
         lower_current = median[0] - atr[0] * m_current;
         
         upper_last = median[1] + atr[1] * m_last;
         lower_last = median[1] - atr[1] * m_last;
         
         // 获取当前买卖价
         double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         // 计算当前买卖价的bias
         double Bias_bid = (current_bid / ma_current) - 1;
         double Bias_ask = (current_ask / ma_current) - 1;
         
         // 交易信号判断
         if(Bias_bid > upper_current && lastBias <= upper_last) return 1;
         else if(Bias_ask < lower_current && lastBias >= lower_last) return -1;
         return 0;
}

//+------------------------------------------------------------------+
//| 动态计算开仓手数                                                    |
//+------------------------------------------------------------------+
double CalculateProperVolume()
{
    // 1. 获取账户和品种信息
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    long   leverage = AccountInfoInteger(ACCOUNT_LEVERAGE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    
    // 2. 计算当前可用风险金额
    double riskAmount = freeMargin * MAX_POSITION_PCT; // 风险控制比例
    if (riskAmount <= 0) return 0;
    
    // 3. 计算1手合约的保证金占用
    double marginPerLot = contractSize * price / leverage;
    
    // 4. 理论手数 = 风险金额 / 每手保证金
    double volume = riskAmount / marginPerLot;
    
    volume = NormalizeDouble(MathFloor(volume / lotStep) * lotStep, (int)MathLog10(1/lotStep));
    volume = MathMin(20.0, MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), volume));
    return volume;
}

//+------------------------------------------------------------------+
//| 关闭指定品种仓位                                                    |
//+------------------------------------------------------------------+
void CloseSymbolPositions(string symbol=NULL, long magic=0)
{
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   
   CPositionInfo posInfo;
   
   if(symbol==NULL) symbol = _Symbol;
   
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket) && 
         posInfo.Symbol()==symbol && 
         (magic==0 || posInfo.Magic()==magic))
      {
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| 紧急平仓所有仓位                                                    |
//+------------------------------------------------------------------+
void EmergencyCloseAll()
{
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   trade.SetTypeFilling(ORDER_FILLING_FOK); // 全部成交否则撤单

   CPositionInfo posInfo;
   CSymbolInfo symInfo;
   
   int closedCount = 0;
   int totalAttempts = 3; // 最大尝试次数
   
   // 平仓尝试循环
   for(int attempt=1; attempt<=totalAttempts; attempt++)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(posInfo.SelectByTicket(ticket))
         {
            string symbol = posInfo.Symbol();
            double volume = posInfo.Volume();
            ENUM_POSITION_TYPE type = posInfo.PositionType();
            
            // 设置交易品种数据
            if(!symInfo.Name(symbol)) continue;
            
            // 准备平仓价格
            double price = (type==POSITION_TYPE_BUY) ? symInfo.Bid() : symInfo.Ask();
            
            // 执行平仓
            if(trade.PositionClose(ticket, 50)) // 
            {
               closedCount++;
               PrintFormat("成功平仓 #%d %s %.2f手", ticket, symbol, volume);
            }
            else
            {
               PrintFormat("平仓失败 #%d 错误: %d", ticket, GetLastError());
            }
         }
      }
      
      // 如果已平完所有仓位则退出
      if(PositionsTotal()==0) break;
      
      // 每次尝试后延迟
      Sleep(300);
   }
   
   // 结果报告
   if(PositionsTotal()==0)
      Print("熔断完成：所有仓位已平仓");
   else
      Alert("警告！未能完全平仓，剩余:", PositionsTotal(), "个仓位");
}
//+------------------------------------------------------------------+
//| MA趋势判断                                                        |
//+------------------------------------------------------------------+
int CheckMATrend()
{
    double fastMA[], slowMA[];
    
    // 从指标缓冲区获取最新MA值
    if(CopyBuffer(fastmaHandle, 0, 1, 1, fastMA) <= 0 || 
       CopyBuffer(slowmaHandle, 0, 1, 1, slowMA) <= 0)
    {
        Print("获取MA数据失败！错误码:", GetLastError());
        return 0;
    }
    
    return (fastMA[0] > slowMA[0]) ? 1 : -1; // 1=多头, -1=空头
}
//+------------------------------------------------------------------+
//| 简单的更新虚拟账户（隔离资金）                                         |
//+------------------------------------------------------------------+
void UpdateVirtualAccount()
{
    floatingProfit = 0;
    usedMargin = 0;
    
    // 遍历所有仓位（仅统计该EA的仓位）
    for(int i=PositionsTotal()-1; i>=0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        
        if(PositionSelectByTicket(ticket) && 
           PositionGetInteger(POSITION_MAGIC) == MAGIC_NUMBER &&
           PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            // 累加保证金（考虑多品种对冲情况）
            usedMargin += accountInfo.MarginCheck(
                _Symbol,
                (ENUM_ORDER_TYPE)PositionGetInteger(POSITION_TYPE),
                PositionGetDouble(POSITION_VOLUME),
                PositionGetDouble(POSITION_PRICE_OPEN)
            );
            
            // 累加浮动盈亏（包含隔夜利息和佣金）
            floatingProfit += PositionGetDouble(POSITION_PROFIT) + 
                            PositionGetDouble(POSITION_SWAP) + 
                            PositionGetDouble(POSITION_COMMISSION);
        }
    }
    
    // 更新虚拟余额
    virtualBalance = TestCapital + floatingProfit - usedMargin;
}

//+------------------------------------------------------------------+
//| 管理吊灯止损                                                       |
//+------------------------------------------------------------------+
/*void ManageChandelierExit()
{
   // 精确遍历当前品种的仓位（带魔术码验证）
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      
      // 三重验证
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER) continue;
      
      // 获取仓位信息
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentPrice = posType == POSITION_TYPE_BUY ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // 计算吊灯止损价
      double exitPrice = GetChandelierExitPrice(_Symbol, posType);
      
      // 执行止损检查
      if((posType == POSITION_TYPE_BUY && currentPrice <= exitPrice) ||
         (posType == POSITION_TYPE_SELL && currentPrice >= exitPrice))
      {
         trade.SetExpertMagicNumber(MAGIC_NUMBER);
         if(!trade.PositionClose(ticket))
         {
            PrintFormat("吊灯止损失败 #%d 错误: %d", ticket, GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 计算吊灯止损价格                                                    |
//+------------------------------------------------------------------+
double GetChandelierExitPrice(string symbol, ENUM_POSITION_TYPE posType)
{      
       Print("---------------吊灯止损--------------------- ");
       // 获取最高价、最低价和ATR数据
       double highs[], lows[], atr[];

       // 1. 获取最高价,如果第三个输入参数为0，则会加入最新未闭合K线数据，如果为1，则是上一个K线数据
       if (CopyHigh(symbol, _Period, 0, CHANDELIER_PERIOD, highs) <= 0) 
       {
           Print("获取最高价数据失败！错误代码：", GetLastError());
           return (posType == POSITION_TYPE_BUY) ? 0 : DBL_MAX;
       }
           
       // 2. 获取最低价
       if (CopyLow(symbol, _Period, 0, CHANDELIER_PERIOD, lows) <= 0)
       {
           Print("获取最低价数据失败！错误代码：", GetLastError());
           return (posType == POSITION_TYPE_BUY) ? 0 : DBL_MAX;
       }
       
       // 3. 获取ATR数据
       if (CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) // 只需要最新的ATR值
       {
           Print("获取ATR数据失败！错误代码：", GetLastError());
           return (posType == POSITION_TYPE_BUY) ? 0 : DBL_MAX;
       }
       
       // 计算吊灯止损价格
       if (posType == POSITION_TYPE_BUY)
       {
           // 多头止损：最高价 - ATR * 乘数
           double highestHigh = highs[ArrayMaximum(highs)];
           //Print("highestHigh=", highestHigh);
           //Print("多头信号价格=", highestHigh - atr[0] * CHANDELIER_MULTIPLIER);
           return highestHigh - atr[0] * CHANDELIER_MULTIPLIER;
       }
       
   
       else
       {
           // 空头止损：最低价 + ATR * 乘数
           double lowestLow = lows[ArrayMinimum(lows)];
           //Print("lowestLow=",lowestLow);
           //Print("空头信号价格=", lowestLow + atr[0] * CHANDELIER_MULTIPLIER);
           return lowestLow + atr[0] * CHANDELIER_MULTIPLIER;
       } 
}*/