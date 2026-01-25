import{_ as a,o as n,c as e,aA as i}from"./chunks/framework.Bg8BcNkn.js";const g=JSON.parse('{"title":"Setup the system","description":"","frontmatter":{},"headers":[],"relativePath":"examples/interchanges.md","filePath":"examples/interchanges.md","lastUpdated":null}'),t={name:"examples/interchanges.md"};function l(p,s,h,d,o,r){return n(),e("div",null,[...s[0]||(s[0]=[i(`<div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    using</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> AustralianElectricityMarkets</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">    import</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> AustralianElectricityMarkets</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">RegionModel</span></span>
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
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">RM </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> AustralianElectricityMarkets</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">.</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">RegionModel</span></span></code></pre></div><div class="language- vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang"></span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">AustralianElectricityMarkets.RegionModel</span></span></code></pre></div><h1 id="Setup-the-system" tabindex="-1">Setup the system <a class="header-anchor" href="#Setup-the-system" aria-label="Permalink to &quot;Setup the system {#Setup-the-system}&quot;">​</a></h1><p>Initialise a connection to manage the market data via duckdb</p><div class="tip custom-block"><p class="custom-block-title">Get the data first!</p><p>You will first need to download the data from the monthly archive, saving them locally in parquet files.</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">tables </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> table_requirements</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">RegionalNetworkConfiguration</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">())</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">map</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(tables) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">do</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> table</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    fetch_table_data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(table, date_range)</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">;</span></span></code></pre></div><p>Only the data requirements for a RegionalNetworkconfiguration are downloaded.</p></div><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">db </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> aem_connect</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">duckdb</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">());</span></span></code></pre></div><p>Instantiate the system</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">sys </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> nem_system</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(db, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">RegionalNetworkConfiguration</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">())</span></span></code></pre></div><div><table>
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

</div><p>Set the horizon to consider for the simulation</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">interval </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> Minute</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">5</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">horizon </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> Hour</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">24</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">start_date </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> DateTime</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">2025</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">1</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">1</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">4</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">0</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">)</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">date_range </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> start_date</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">:</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">interval</span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">:</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(start_date </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">+</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> horizon)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">@show</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> date_range</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">map</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">([</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:BIDDAYOFFER_D</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">:BIDPEROFFER_D</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">]) </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">do</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> table</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    fetch_table_data</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(table, date_range)</span></span>
<span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">end</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">;</span></span></code></pre></div><div class="language- vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang"></span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">date_range = Dates.DateTime(&quot;2025-01-01T04:00:00&quot;):Dates.Minute(5):Dates.DateTime(&quot;2025-01-02T04:00:00&quot;)</span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Set cache directory to /home/runner/.nemweb_cache</span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Set filesystem to local       </span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Populating database with data from 2025-01-01 04:00:00 to 2025-01-01 04:00:00</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">  0%|          | 0/1 [00:00&lt;?, ?it/s]</span><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Checking if data already exists for BIDDAYOFFER_D 2025 / 1</span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Data already exists for BIDDAYOFFER_D 2025 / 1, skipping download. Use force_new=True to overwrite.</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">100%|██████████| 1/1 [00:00&lt;00:00, 82.85it/s]</span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Set cache directory to /home/runner/.nemweb_cache</span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Set filesystem to local       </span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Populating database with data from 2025-01-01 04:00:00 to 2025-01-01 04:00:00</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">  0%|          | 0/1 [00:00&lt;?, ?it/s]</span><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:10</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Checking if data already exists for BIDPEROFFER_D 2025 / 1</span></span>
<span class="line"><span style="--shiki-light:#24292e80;--shiki-dark:#e1e4e880;">2026-01-25 09:07:12</span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;"> [</span><span style="--shiki-light:#28a745;--shiki-light-font-weight:bold;--shiki-dark:#34d058;--shiki-dark-font-weight:bold;">info     </span><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">] </span><span style="--shiki-light:#24292e;--shiki-light-font-weight:bold;--shiki-dark:#e1e4e8;--shiki-dark-font-weight:bold;">Data already exists for BIDPEROFFER_D 2025 / 1, skipping download. Use force_new=True to overwrite.</span></span>
<span class="line"></span>
<span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">100%|██████████| 1/1 [00:01&lt;00:00,  1.72s/it]</span></span>
<span class="line"><span style="--shiki-light:#24292e;--shiki-dark:#e1e4e8;">100%|██████████| 1/1 [00:01&lt;00:00,  1.72s/it]</span></span></code></pre></div><p>Set deterministic timseries</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>set_demand!(sys, db, date_range; resolution = interval)</span></span>
<span class="line"><span>set_renewable_pv!(sys, db, date_range; resolution = interval)</span></span>
<span class="line"><span>set_renewable_wind!(sys, db, date_range; resolution = interval)</span></span>
<span class="line"><span>set_hydro_limits!(sys, db, date_range; resolution = interval)</span></span>
<span class="line"><span>set_market_bids!(sys, db, date_range)</span></span></code></pre></div><p>Derive forecasts from the deterministic timseries</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>transform_single_time_series!(</span></span>
<span class="line"><span>    sys,</span></span>
<span class="line"><span>    horizon,</span></span>
<span class="line"><span>    interval, # interval</span></span>
<span class="line"><span>);</span></span>
<span class="line"><span></span></span>
<span class="line"><span>@show sys</span></span></code></pre></div><h1 id="Dispatch" tabindex="-1">Dispatch <a class="header-anchor" href="#Dispatch" aria-label="Permalink to &quot;Dispatch {#Dispatch}&quot;">​</a></h1><p><code>PowerSimulation.jl</code> provides different utilities to simulate an electricity system.</p><p>The following section demonstrates the definition of an economic dispatch problem, where all units in the NEM need to to be dispatched at the lowest cost to meet the aggregate demand at each region.</p><div class="language-julia vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">julia</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">begin</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    template </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> ProblemTemplate</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">()</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, Line, StaticBranch)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, PowerLoad, StaticPowerLoad)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, RenewableDispatch, RenewableFullDispatch)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, ThermalStandard, ThermalBasicDispatch)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, HydroDispatch, HydroDispatchRunOfRiver)</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_network_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, </span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">NetworkModel</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(AreaBalancePowerModel; use_slacks </span><span style="--shiki-light:#D73A49;--shiki-dark:#F97583;">=</span><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;"> true</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">))</span></span>
<span class="line"><span style="--shiki-light:#005CC5;--shiki-dark:#79B8FF;">    set_device_model!</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">(template, AreaInterchange, StaticBranch)</span></span>
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
      <td style = "text-align: left;">PowerSimulations.AreaBalancePowerModel</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Slacks</td>
      <td style = "text-align: left;">true</td>
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
      <td style = "text-align: left;">PowerSystems.AreaInterchange</td>
      <td style = "text-align: left;">PowerSimulations.StaticBranch</td>
      <td style = "text-align: left;">false</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerSystems.Line</td>
      <td style = "text-align: left;">PowerSimulations.StaticBranch</td>
      <td style = "text-align: left;">false</td>
    </tr>
  </tbody>
</table>
</div><p>The Economic Dispatch problem will be solved with open source solver HiGHS, and a relatively large mip gap for the purposes of this example.</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>solver = optimizer_with_attributes(HiGHS.Optimizer, &quot;mip_rel_gap&quot; =&gt; 0.2)</span></span>
<span class="line"><span></span></span>
<span class="line"><span></span></span>
<span class="line"><span>problem = DecisionModel(template, sys; optimizer = solver, horizon = horizon)</span></span>
<span class="line"><span>build!(problem; output_dir = joinpath(tempdir(), &quot;out&quot;))</span></span></code></pre></div><p>Solve the problem</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>solve!(problem)</span></span></code></pre></div><p>Observe the results</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>res = OptimizationProblemResults(problem)</span></span></code></pre></div><p>Lets observe how the units are dispatched</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>begin</span></span>
<span class="line"><span>    renewables = read_variable(res, &quot;ActivePowerVariable__RenewableDispatch&quot;)</span></span>
<span class="line"><span>    thermal = read_variable(res, &quot;ActivePowerVariable__ThermalStandard&quot;)</span></span>
<span class="line"><span>    hydro = read_variable(res, &quot;ActivePowerVariable__HydroDispatch&quot;)</span></span>
<span class="line"><span>    gens_long = vcat(renewables, thermal, hydro)</span></span>
<span class="line"><span>    select!(gens_long, :DateTime, :name =&gt; :DUID, :value)</span></span>
<span class="line"><span></span></span>
<span class="line"><span>    by_fuel = @chain select(</span></span>
<span class="line"><span>        read_units(db),</span></span>
<span class="line"><span>        [:DUID, :STATIONID, :CO2E_ENERGY_SOURCE, :REGIONID]</span></span>
<span class="line"><span>    ) begin</span></span>
<span class="line"><span>        rightjoin(gens_long, on = :DUID)</span></span>
<span class="line"><span>        groupby([:CO2E_ENERGY_SOURCE, :REGIONID, :DateTime])</span></span>
<span class="line"><span>        combine(:value =&gt; sum =&gt; :value)</span></span>
<span class="line"><span>        subset(:value =&gt; ByRow(&gt;(0.0)))</span></span>
<span class="line"><span>        dropmissing!</span></span>
<span class="line"><span>        select!(</span></span>
<span class="line"><span>            :DateTime, :REGIONID, :CO2E_ENERGY_SOURCE =&gt; :Source,</span></span>
<span class="line"><span>            :value</span></span>
<span class="line"><span>        )</span></span>
<span class="line"><span>    end</span></span>
<span class="line"><span></span></span>
<span class="line"><span></span></span>
<span class="line"><span>    loads = @chain res begin</span></span>
<span class="line"><span>        read_parameter(&quot;ActivePowerTimeSeriesParameter__PowerLoad&quot;)</span></span>
<span class="line"><span>        transform!(</span></span>
<span class="line"><span>            :name =&gt; ByRow(x -&gt; split(x, &quot; &quot;)[1]) =&gt; :REGIONID</span></span>
<span class="line"><span>        )</span></span>
<span class="line"><span>        subset!(:REGIONID =&gt; ByRow(!=(&quot;SNOWY1&quot;)))</span></span>
<span class="line"><span>        insertcols!(</span></span>
<span class="line"><span>            :Source =&gt; &quot;Region demand&quot;</span></span>
<span class="line"><span>        )</span></span>
<span class="line"><span>        select!(</span></span>
<span class="line"><span>            :DateTime, :REGIONID, :Source,</span></span>
<span class="line"><span>            :value =&gt; ByRow(-) =&gt; :value</span></span>
<span class="line"><span>        )</span></span>
<span class="line"><span>    end</span></span>
<span class="line"><span></span></span>
<span class="line"><span></span></span>
<span class="line"><span>    demand = data(loads) * mapping(</span></span>
<span class="line"><span>        :DateTime, :value, color = :Source, layout = :REGIONID</span></span>
<span class="line"><span>    ) * visual(Lines, linestyle = (:dash, :dense))</span></span>
<span class="line"><span>    generation = data(by_fuel) * mapping(</span></span>
<span class="line"><span>        :DateTime, :value, color = :Source, layout = :REGIONID</span></span>
<span class="line"><span>    ) * visual(Lines)</span></span>
<span class="line"><span></span></span>
<span class="line"><span>    draw(</span></span>
<span class="line"><span>        demand + generation;</span></span>
<span class="line"><span>        figure = (; size = (1000, 800)),</span></span>
<span class="line"><span>        legend = (; position = :bottom)</span></span>
<span class="line"><span>    )</span></span>
<span class="line"><span>end</span></span></code></pre></div><p>Let&#39;s observe the dispatch of a few thermal generators</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>function filter_non_all_zero(df, group_by, value)</span></span>
<span class="line"><span>    gdf = groupby(df, group_by)</span></span>
<span class="line"><span>    is_all_zero = combine(gdf, :value =&gt; (x -&gt; all(x == 0)) =&gt; :all_zero)</span></span>
<span class="line"><span>    subset!(is_all_zero, :all_zero =&gt; x -&gt; .!x)</span></span>
<span class="line"><span>    return innerjoin(df, is_all_zero, on = group_by)</span></span>
<span class="line"><span>end</span></span>
<span class="line"><span></span></span>
<span class="line"><span>begin</span></span>
<span class="line"><span>    thermals_non_zero = filter_non_all_zero(thermal, :name, :value)</span></span>
<span class="line"><span>    sample = first(unique(thermals_non_zero.name), 5)</span></span>
<span class="line"><span>    sample = subset!(thermals_non_zero, :name =&gt; ByRow(in(sample)))</span></span>
<span class="line"><span>    spec = data(sample) * mapping(:DateTime, :value, color = :name) * visual(Lines)</span></span>
<span class="line"><span>    draw(spec; figure = (; size = (500, 500)))</span></span>
<span class="line"><span>end</span></span></code></pre></div><p>Let&#39;s observe the dispatch of a few renewable generators</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>begin</span></span>
<span class="line"><span>    renewables_non_zero = filter_non_all_zero(renewables, :name, :value)</span></span>
<span class="line"><span>    sample = first(unique(renewables_non_zero.name), 5)</span></span>
<span class="line"><span>    sample = subset!(renewables_non_zero, :name =&gt; ByRow(in(sample)))</span></span>
<span class="line"><span>    data(sample) * mapping(:DateTime, :value, color = :name) * visual(Lines) |&gt; draw</span></span>
<span class="line"><span>end</span></span></code></pre></div><p>Notice that most solar generators are actually <strong>not</strong> dispatched during the day here even though the solar output is definitely non-zero.</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>begin</span></span>
<span class="line"><span>    ren = get_component(RenewableDispatch, sys, &quot;COLEASF1&quot;)</span></span>
<span class="line"><span>    ts = get_time_series_array(Deterministic, ren, &quot;max_active_power&quot;) |&gt; DataFrame</span></span>
<span class="line"><span>    index, values = ts.timestamp, ts.A * 100</span></span>
<span class="line"><span>    fig = Figure()</span></span>
<span class="line"><span>    ax = Axis(fig[1, 1], xlabel = &quot;timestamp&quot;, title = &quot;Max active power [MW]&quot;, ylabel = &quot;MW&quot;)</span></span>
<span class="line"><span>    lines!(index, values; label = &quot;COLEASF1&quot;)</span></span>
<span class="line"><span>    axislegend(ax)</span></span>
<span class="line"><span>    fig</span></span>
<span class="line"><span>end</span></span></code></pre></div><p>This was not observed in the Economic dispatch example, and is due to the fact that the market bids ( in the Australian Electricity market) incorporate the on/off constraints: Coal power plant bid at lower costs than solar plants because it is more expensive for them to turn off, and they know they should be able to recoup the losses at time of low solar generation, where there is less competition.</p><div class="language-@example vp-adaptive-theme"><button title="Copy Code" class="copy"></button><span class="lang">@example</span><pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span>begin</span></span>
<span class="line"><span>    interchange_flow = read_variable(res, &quot;FlowActivePowerVariable__AreaInterchange&quot;)</span></span>
<span class="line"><span>    spec = data(interchange_flow) * mapping(:DateTime, :value =&gt; &quot;Interchange flow (MW)&quot;, color = :name) * visual(Lines)</span></span>
<span class="line"><span>    draw(spec; figure = (; size = (500, 500)))</span></span>
<span class="line"><span>end</span></span></code></pre></div>`,37)])])}const c=a(t,[["render",l]]);export{g as __pageData,c as default};
