import{_ as i,o as t,c as a,aA as n}from"./chunks/framework.RqrAmmgJ.js";const l="/AustralianElectricityMarkets.jl/previews/PR43/assets/rzrcqlz.D9LPFaTl.png",e="/AustralianElectricityMarkets.jl/previews/PR43/assets/zkxdtse.DViLMu53.png",h="/AustralianElectricityMarkets.jl/previews/PR43/assets/zaoolub.B6ryGyEh.png",k="/AustralianElectricityMarkets.jl/previews/PR43/assets/vyirrzx.BaMnrQzW.png",f=JSON.parse('{"title":"Setup the system","description":"","frontmatter":{},"headers":[],"relativePath":"examples/economic_dispatch.md","filePath":"examples/economic_dispatch.md","lastUpdated":null}'),p={name:"examples/economic_dispatch.md"};function d(r,s,g,o,y,E){return t(),a("div",null,[...s[0]||(s[0]=[n(`<div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> AustralianElectricityMarkets</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> PowerSystems</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> PowerSimulations</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> HydroPowerSimulations</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> Chain</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> DataFrames</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> AlgebraOfGraphics, CairoMakie</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> TidierDB</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> Dates</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> HiGHS</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span></code></pre></div><h1 id="Setup-the-system" tabindex="-1">Setup the system <a class="header-anchor" href="#Setup-the-system" aria-label="Permalink to &quot;Setup the system {#Setup-the-system}&quot;">​</a></h1><p>Initialise a connection to manage the market data via duckdb</p><div class="tip custom-block"><p class="custom-block-title">Get the data first!</p></div><p>You will first need to download the data from the monthly archive, saving them locally in parquet files.</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">tables </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> table_requirements</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">RegionalNetworkConfiguration</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">())</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">map</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(tables) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">do</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> table</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    fetch_table_data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(table, date_range)</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">;</span></span></code></pre></div><p>Only the data requirements for a RegionalNetworkconfiguration are downloaded.</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">db </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> aem_connect</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">duckdb</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">());</span></span></code></pre></div><p>Instantiate the system</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">sys </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> nem_system</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(db, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">RegionalNetworkConfiguration</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">())</span></span></code></pre></div><div><table>
  <thead>
    <tr class = "title">
      <td colspan = "2" style = "font-size: x-large; font-weight: bold; text-align: center;">System</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Property</th>
      <th style = "font-weight: bold; text-align: left;">Value</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">Name</td>
      <td style = "text-align: left;"></td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Description</td>
      <td style = "text-align: left;"></td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">System Units Base</td>
      <td style = "text-align: left;">SYSTEM_BASE</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Base Power</td>
      <td style = "text-align: left;">100.0</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Base Frequency</td>
      <td style = "text-align: left;">60.0</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Num Components</td>
      <td style = "text-align: left;">602</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "2" style = "font-size: x-large; font-weight: bold; text-align: center;">Static Components</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Type</th>
      <th style = "font-weight: bold; text-align: left;">Count</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">ACBus</td>
      <td style = "text-align: left;">12</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Arc</td>
      <td style = "text-align: left;">12</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Area</td>
      <td style = "text-align: left;">6</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">AreaInterchange</td>
      <td style = "text-align: left;">8</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">EnergyReservoirStorage</td>
      <td style = "text-align: left;">31</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">HydroDispatch</td>
      <td style = "text-align: left;">84</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Line</td>
      <td style = "text-align: left;">14</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerLoad</td>
      <td style = "text-align: left;">6</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">RenewableDispatch</td>
      <td style = "text-align: left;">222</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ThermalStandard</td>
      <td style = "text-align: left;">199</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">TransmissionInterface</td>
      <td style = "text-align: left;">8</td>
    </tr>
  </tbody>
</table>

</div><p>Set the horizon to consider for the simulation</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">date_range </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> Date</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">2025</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">1</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">2</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">:</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">Date</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">2025</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">1</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">3</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">interval </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> Minute</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">30</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">horizon </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> Hour</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">24</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span></code></pre></div><div class="language- vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang"></span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">24 hours</span></span></code></pre></div><p>Set deterministic timseries</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">set_demand!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sys, db, date_range; resolution </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> interval)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">set_renewable_pv!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sys, db, date_range; resolution </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> interval)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">set_renewable_wind!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sys, db, date_range; resolution </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> interval)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">set_hydro_limits!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sys, db, date_range; resolution </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> interval)</span></span></code></pre></div><div class="language- vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang"></span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for SNOWY1 Load</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting PV power time series</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting wind power time series</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for EILDON3</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for HLMSEW01</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for PINDARI</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for PALOONA</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for KEEPIT</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for RUBICON</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for COPTNHYD</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for PUMP2</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for WYANGALA</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for YWNGAHYD</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for CLOVER</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for ROWALLAN</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for GUTHNL1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for GLENMAG1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for WYANGALB</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for BROWNMT</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for L_W_CNL1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for MURAYNL3</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for BURRIN</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for CLUNY</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for PUMP1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for REPULSE</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for KAREEYA5</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for PO110NL1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for TUMT3NL2</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for WYA252B1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for GLBWNHYD</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for JOUNAMA1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for JNDABNE1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for SNOWYGJP</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for GOVILLB1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for BAPS</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for TUMT3NL1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for TRIBNL1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for THEDROP1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for ADPMH1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for MURAYNL2</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for BUTLERSG</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for TUMT3NL3</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for BDONGHYD</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for WILLHOV1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for MURAYNL1</span></span>
<span class="line"><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">[ </span><span style="--shiki-light:#1b7c83;--shiki-light-font-weight:bold;--shiki-dark:#39c5cf;--shiki-dark-font-weight:bold;">Info: </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">Setting loads to 0 for WYB252B1</span></span></code></pre></div><p>Derive forecasts from the deterministic timseries</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">transform_single_time_series!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    sys,</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    horizon, </span><span style="--shiki-light:#6A737D;--shiki-dark:#6A737D;"># horizon</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    interval, </span><span style="--shiki-light:#6A737D;--shiki-dark:#6A737D;"># interval</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">);</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">@show</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> sys</span></span></code></pre></div><div><table>
  <thead>
    <tr class = "title">
      <td colspan = "2" style = "font-size: x-large; font-weight: bold; text-align: center;">System</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Property</th>
      <th style = "font-weight: bold; text-align: left;">Value</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">Name</td>
      <td style = "text-align: left;"></td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Description</td>
      <td style = "text-align: left;"></td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">System Units Base</td>
      <td style = "text-align: left;">SYSTEM_BASE</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Base Power</td>
      <td style = "text-align: left;">100.0</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Base Frequency</td>
      <td style = "text-align: left;">60.0</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Num Components</td>
      <td style = "text-align: left;">602</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "2" style = "font-size: x-large; font-weight: bold; text-align: center;">Static Components</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Type</th>
      <th style = "font-weight: bold; text-align: left;">Count</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">ACBus</td>
      <td style = "text-align: left;">12</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Arc</td>
      <td style = "text-align: left;">12</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Area</td>
      <td style = "text-align: left;">6</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">AreaInterchange</td>
      <td style = "text-align: left;">8</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">EnergyReservoirStorage</td>
      <td style = "text-align: left;">31</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">HydroDispatch</td>
      <td style = "text-align: left;">84</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Line</td>
      <td style = "text-align: left;">14</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerLoad</td>
      <td style = "text-align: left;">6</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">RenewableDispatch</td>
      <td style = "text-align: left;">222</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ThermalStandard</td>
      <td style = "text-align: left;">199</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">TransmissionInterface</td>
      <td style = "text-align: left;">8</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "8" style = "font-size: x-large; font-weight: bold; text-align: center;">StaticTimeSeries Summary</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">owner_type</th>
      <th style = "font-weight: bold; text-align: left;">owner_category</th>
      <th style = "font-weight: bold; text-align: left;">name</th>
      <th style = "font-weight: bold; text-align: left;">time_series_type</th>
      <th style = "font-weight: bold; text-align: left;">initial_timestamp</th>
      <th style = "font-weight: bold; text-align: left;">resolution</th>
      <th style = "font-weight: bold; text-align: left;">count</th>
      <th style = "font-weight: bold; text-align: left;">time_step_count</th>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Int64</th>
      <th style = "text-align: left;">Int64</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">HydroDispatch</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">SingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-02T00:00:00</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">84</td>
      <td style = "text-align: left;">48</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerLoad</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">SingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-02T00:00:00</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">6</td>
      <td style = "text-align: left;">48</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">RenewableDispatch</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">SingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-02T00:00:00</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">222</td>
      <td style = "text-align: left;">48</td>
    </tr>
  </tbody>
</table>
<table>
  <thead>
    <tr class = "title">
      <td colspan = "10" style = "font-size: x-large; font-weight: bold; text-align: center;">Forecast Summary</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">owner_type</th>
      <th style = "font-weight: bold; text-align: left;">owner_category</th>
      <th style = "font-weight: bold; text-align: left;">name</th>
      <th style = "font-weight: bold; text-align: left;">time_series_type</th>
      <th style = "font-weight: bold; text-align: left;">initial_timestamp</th>
      <th style = "font-weight: bold; text-align: left;">resolution</th>
      <th style = "font-weight: bold; text-align: left;">count</th>
      <th style = "font-weight: bold; text-align: left;">horizon</th>
      <th style = "font-weight: bold; text-align: left;">interval</th>
      <th style = "font-weight: bold; text-align: left;">window_count</th>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Int64</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Int64</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">HydroDispatch</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">DeterministicSingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-02T00:00:00</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">84</td>
      <td style = "text-align: left;">1 day</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">1</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerLoad</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">DeterministicSingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-02T00:00:00</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">6</td>
      <td style = "text-align: left;">1 day</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">1</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">RenewableDispatch</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">DeterministicSingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-02T00:00:00</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">222</td>
      <td style = "text-align: left;">1 day</td>
      <td style = "text-align: left;">30 minutes</td>
      <td style = "text-align: left;">1</td>
    </tr>
  </tbody>
</table>
</div><h1 id="Economic-dispatch" tabindex="-1">Economic dispatch <a class="header-anchor" href="#Economic-dispatch" aria-label="Permalink to &quot;Economic dispatch {#Economic-dispatch}&quot;">​</a></h1><p><code>PowerSimulation.jl</code> provides different utilities to simulate an electricity system.</p><p>The following section demonstrates the definition of an economic dispatch problem, where all units in the NEM need to to be dispatched at the lowest cost to meet the aggregate demand at each region.</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    template </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ProblemTemplate</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">()</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, Line, StaticBranch)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, PowerLoad, StaticPowerLoad)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, RenewableDispatch, RenewableFullDispatch)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, ThermalStandard, ThermalBasicDispatch)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, HydroDispatch, HydroDispatchRunOfRiver)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_network_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">NetworkModel</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(CopperPlatePowerModel))</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    template</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span></code></pre></div><div><table>
  <thead>
    <tr class = "title">
      <td colspan = "2" style = "font-size: x-large; font-weight: bold; text-align: center;">Network Model</td>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">Network Model</td>
      <td style = "text-align: left;">PowerSimulations.CopperPlatePowerModel</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Slacks</td>
      <td style = "text-align: left;">false</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PTDF</td>
      <td style = "text-align: left;">false</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Duals</td>
      <td style = "text-align: left;">None</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">HVDC Network Model</td>
      <td style = "text-align: left;">None</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "3" style = "font-size: x-large; font-weight: bold; text-align: center;">Device Models</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Device Type</th>
      <th style = "font-weight: bold; text-align: left;">Formulation</th>
      <th style = "font-weight: bold; text-align: left;">Slacks</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerSystems.ThermalStandard</td>
      <td style = "text-align: left;">PowerSimulations.ThermalBasicDispatch</td>
      <td style = "text-align: left;">false</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerSystems.PowerLoad</td>
      <td style = "text-align: left;">PowerSimulations.StaticPowerLoad</td>
      <td style = "text-align: left;">false</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerSystems.RenewableDispatch</td>
      <td style = "text-align: left;">PowerSimulations.RenewableFullDispatch</td>
      <td style = "text-align: left;">false</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerSystems.HydroDispatch</td>
      <td style = "text-align: left;">HydroPowerSimulations.HydroDispatchRunOfRiver</td>
      <td style = "text-align: left;">false</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "3" style = "font-size: x-large; font-weight: bold; text-align: center;">Branch Models</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Branch Type</th>
      <th style = "font-weight: bold; text-align: left;">Formulation</th>
      <th style = "font-weight: bold; text-align: left;">Slacks</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerSystems.Line</td>
      <td style = "text-align: left;">PowerSimulations.StaticBranch</td>
      <td style = "text-align: left;">false</td>
    </tr>
  </tbody>
</table>
</div><p>The Economic Dispatch problem will be solved with open source solver HiGHS, and a relatively large mip gap for the purposes of this example.</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">solver </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> optimizer_with_attributes</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(HiGHS</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">Optimizer, </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;mip_rel_gap&quot;</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> 0.2</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">problem </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> DecisionModel</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, sys; optimizer </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> solver, horizon </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> horizon)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">build!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(problem; output_dir </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> joinpath</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">tempdir</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(), </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;out&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">))</span></span></code></pre></div><div class="language- vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang"></span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">InfrastructureSystems.Optimization.ModelBuildStatusModule.ModelBuildStatus.BUILT = 0</span></span></code></pre></div><p>Solve the problem</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">solve!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(problem)</span></span></code></pre></div><div class="language- vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang"></span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">InfrastructureSystems.Simulation.RunStatusModule.RunStatus.SUCCESSFULLY_FINALIZED = 0</span></span></code></pre></div><p>Observe the results</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">res </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> OptimizationProblemResults</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(problem)</span></span></code></pre></div><div><p> Start: 2025-01-02T00:00:00</p>
<p> End: 2025-01-02T23:30:00</p>
<p> Resolution: 30 minutes</p>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "1" style = "font-size: x-large; font-weight: bold; text-align: center;">PowerSimulations Problem Auxiliary variables Results</td>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">HydroEnergyOutput__HydroDispatch</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "1" style = "font-size: x-large; font-weight: bold; text-align: center;">PowerSimulations Problem Expressions Results</td>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">ProductionCostExpression__HydroDispatch</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ActivePowerBalance__System</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">FuelConsumptionExpression__ThermalStandard</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ProductionCostExpression__RenewableDispatch</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ProductionCostExpression__ThermalStandard</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "1" style = "font-size: x-large; font-weight: bold; text-align: center;">PowerSimulations Problem Parameters Results</td>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">ActivePowerTimeSeriesParameter__PowerLoad</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ActivePowerTimeSeriesParameter__RenewableDispatch</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ActivePowerTimeSeriesParameter__HydroDispatch</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "1" style = "font-size: x-large; font-weight: bold; text-align: center;">PowerSimulations Problem Variables Results</td>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">ActivePowerVariable__RenewableDispatch</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ActivePowerVariable__ThermalStandard</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ActivePowerVariable__HydroDispatch</td>
    </tr>
  </tbody>
</table>
</div><p>Lets observe how the units are dispatched</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    renewables </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> read_variable</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(res, </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;ActivePowerVariable__RenewableDispatch&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    thermal </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> read_variable</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(res, </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;ActivePowerVariable__ThermalStandard&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    hydro </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> read_variable</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(res, </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;ActivePowerVariable__HydroDispatch&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    gens_long </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> vcat</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(renewables, thermal, hydro)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    select!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(gens_long, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:name</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :DUID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    by_fuel </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> @chain</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> select</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        read_units</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(db),</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        [</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:DUID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:STATIONID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:CO2E_ENERGY_SOURCE</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:REGIONID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">]</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    ) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        rightjoin</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(gens_long, on </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :DUID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        groupby</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">([</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:CO2E_ENERGY_SOURCE</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:REGIONID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">])</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        combine</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> sum </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        subset</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ByRow</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">0.0</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)))</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        dropmissing!</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        select!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">            :DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:REGIONID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:CO2E_ENERGY_SOURCE</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :Source</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">,</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">            :value</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        )</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    end</span></span>
<span class="line"></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    loads </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> @chain</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> res </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        read_parameter</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;ActivePowerTimeSeriesParameter__PowerLoad&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        transform!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">            :name</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ByRow</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(x </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">-&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> split</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(x, </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot; &quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)[</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">1</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">]) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :REGIONID</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        )</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        subset!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:REGIONID</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ByRow</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">!=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;SNOWY1&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)))</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        insertcols!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">            :Source</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;"> &quot;Region demand&quot;</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        )</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        select!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">            :DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:REGIONID</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:Source</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">,</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">            :value</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ByRow</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">-</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :value</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        )</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    end</span></span>
<span class="line"></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    demand </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(loads) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> mapping</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        :DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, color </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :Source</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, layout </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :REGIONID</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    ) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> visual</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(Lines, linestyle </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> (</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:dash</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:dense</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">))</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    generation </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(by_fuel) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> mapping</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">        :DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, color </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :Source</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, layout </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :REGIONID</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    ) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> visual</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(Lines)</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    draw</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        demand </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">+</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> generation;</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        figure </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> (; size </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> (</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">1000</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">800</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)),</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        legend </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> (; position </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :bottom</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    )</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span></code></pre></div><p><img src="`+l+`" alt="" width="1000px" height="800px"></p><p>Let&#39;s observe the dispatch of a few thermal generators</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">function</span><span style="--shiki-light:#6F42C1;--shiki-dark:#B392F0;"> filter_non_all_zero</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(df, group_by, value)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    gdf </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> groupby</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(df, group_by)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    is_all_zero </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> combine</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(gdf, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> (x </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">-&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> all</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(x </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">==</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> 0</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :all_zero</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    subset!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(is_all_zero, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:all_zero</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> x </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">-&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> .</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">x)</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    return</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> innerjoin</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(df, is_all_zero, on </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> group_by)</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    thermals_non_zero </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> filter_non_all_zero</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(thermal, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:name</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    sample </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> first</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">unique</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(thermals_non_zero</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">name), </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">5</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    sample </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> subset!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(thermals_non_zero, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:name</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ByRow</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">in</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sample)))</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sample) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> mapping</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, color </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :name</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> visual</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(Lines) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">|&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> draw</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span></code></pre></div><p><img src="`+e+`" alt="" width="600px" height="450px"></p><p>Let&#39;s observe the dispatch of a few renewable generators</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    renewables_non_zero </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> filter_non_all_zero</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(renewables, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:name</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    sample </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> first</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">unique</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(renewables_non_zero</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">name), </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">5</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    sample </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> subset!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(renewables_non_zero, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:name</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ByRow</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">in</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sample)))</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sample) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> mapping</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, color </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :name</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> visual</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(Lines) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">|&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> draw</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span></code></pre></div><p><img src="`+h+`" alt="" width="600px" height="450px"></p><p>Let&#39;s observe the dispatch of a few hydro generators</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    hydro_non_zero </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> filter_non_all_zero</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(hydro, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:name</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    sample </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> first</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">unique</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(hydro_non_zero</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">name), </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">5</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    sample </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> subset!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(hydro_non_zero, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:name</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;"> =&gt;</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ByRow</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">in</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sample)))</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(sample) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> mapping</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:value</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, color </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> :name</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">*</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> visual</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(Lines) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">|&gt;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> draw</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span></code></pre></div><p><img src="`+k+'" alt="" width="600px" height="450px"></p>',46)])])}const b=i(p,[["render",d]]);export{f as __pageData,b as default};
