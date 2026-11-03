"""Regenerate descriptive README figures from the completed local Parquet data."""
from __future__ import annotations
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import polars as pl

from common import ROOT
BASE=ROOT/'data/processed/history'
OUT=ROOT/'reports/figures'
START='<!-- EXPLORATORY SUMMARY START -->'
END='<!-- EXPLORATORY SUMMARY END -->'


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    paths=sorted((BASE/'flights_model_ready').glob('year=*/month=*/part.parquet'))
    masters=sorted((BASE/'flights_master').glob('year=*/month=*/part.parquet'))
    if len(paths)!=36 or len(masters)!=36:raise RuntimeError('Expected 36 complete modeling and master partitions.')
    f=pl.scan_parquet(paths, hive_partitioning=True).select('FlightDate','Origin','CRSDepTime','departure_delay_minutes','year','month')
    d=pl.col('departure_delay_minutes');hour=(pl.col('CRSDepTime').cast(pl.Int32,strict=False)//100)%24
    basic=f.select(pl.len().alias('n'),d.mean().alias('mean'),d.median().alias('median'),d.quantile(.9).alias('p90'),(d<0).sum().alias('early'),(d>=15).sum().alias('late15'),(d< -30).sum().alias('below_window'),(d>=120).sum().alias('above_window')).collect(engine='streaming').row(0,named=True)
    # Two-minute bins cover [-30, 120); tails are counted separately below.
    bins=(f.filter((d >= -30)&(d < 120)).select(((d/2).floor().cast(pl.Int32)*2).alias('bin')).group_by('bin').len().sort('bin').collect(engine='streaming'))
    data={r['bin']:r['len'] for r in bins.to_dicts()}; n=basic['n']
    edges=list(range(-30,120,2)); values=[data.get(i,0)*100/n for i in edges]
    plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False,'figure.facecolor':'white'})
    fig,ax=plt.subplots(figsize=(10,4.6),layout='constrained')
    ax.bar(edges,values,width=2,align='edge',color=['#177e89' if i<0 else '#e49c46' for i in edges],edgecolor='white',linewidth=.25)
    ax.axvline(0,color='#384b56',linewidth=.8,alpha=.7)
    ax.set_xlim(-30,120);ax.set_xticks(range(-30,121,15));ax.set_ylabel('Share of eligible flights per 2-minute bin (%)');ax.set_xlabel('Departure delay (minutes)');ax.set_title('Distribution of departure delays, 2023–2025',loc='left',weight='bold');ax.grid(axis='y',alpha=.2);ax.set_axisbelow(True)
    fig.savefig(OUT/'delay_distribution.png',dpi=170);plt.close(fig)
    hourly=f.with_columns(hour.alias('hour')).filter(pl.col('hour').is_not_null()).group_by('hour').agg(pl.len().alias('n'),d.mean().alias('mean'),(d>=15).mean().alias('late_rate')).sort('hour').collect(engine='streaming')
    fig,ax=plt.subplots(figsize=(9,4.2),layout='constrained'); ax.plot(hourly['hour'],[r['mean'] if r['n']>=1000 else float('nan') for r in hourly.to_dicts()],marker='o',lw=2,color='#177e89');ax.set_xticks(range(0,24,2));ax.set_xlabel('Scheduled departure hour (local airport time)');ax.set_ylabel('Mean departure delay (minutes)');ax.set_title('Departure delay by scheduled hour',loc='left',weight='bold');ax.grid(alpha=.2);fig.savefig(OUT/'delay_by_hour.png',dpi=170);plt.close(fig)
    monthly=f.group_by('year','month').agg(pl.len().alias('n'),d.mean().alias('mean'),(d>=15).mean().alias('late_rate')).sort('year','month').collect(engine='streaming')
    x=list(range(monthly.height)); fig,ax=plt.subplots(figsize=(10,4.2),layout='constrained');ax.plot(x,monthly['mean'],lw=1.8,color='#177e89');ax.scatter(x,monthly['mean'],s=12,color='#177e89');ax.set_xticks([0,6,12,18,24,30],['Jan 2023','Jul 2023','Jan 2024','Jul 2024','Jan 2025','Jul 2025'],rotation=20);ax.set_ylabel('Mean departure delay (minutes)');ax.set_title('Monthly mean departure delay',loc='left',weight='bold');ax.grid(alpha=.2);fig.savefig(OUT/'delay_by_month.png',dpi=170);plt.close(fig)
    annual=f.group_by('year').agg(pl.len().alias('eligible'),d.mean().alias('mean'),d.median().alias('median'),(d>=15).mean().alias('late_rate')).sort('year').collect(engine='streaming')
    master=pl.scan_parquet(masters,hive_partitioning=True).group_by('year').agg(pl.len().alias('scheduled'),(pl.col('Cancelled')==1).sum().alias('cancelled')).collect(engine='streaming')
    yearly=annual.join(master,on='year',how='left',validate='1:1').sort('year');yearly.write_csv(OUT/'annual_summary.csv')
    airport=f.group_by('Origin').agg(pl.len().alias('n'),d.mean().alias('mean'),(d>=15).mean().alias('late_rate')).sort('n',descending=True).head(5).collect(engine='streaming');airport.write_csv(OUT/'top_airports.csv')
    content=f'''{START}
## Exploratory summary

The figures use **{n:,} eligible non-cancelled flights** in the 2023–2025 modeling dataset, not all scheduled flights. Delay is the signed BTS departure delay: negative values are early. These are unadjusted descriptions, not estimates of causal effects. Cancellations are included only in the annual scheduled-flight table below.

| Statistic | Value |
|---|---:|
| Mean departure delay | {basic['mean']:.1f} min |
| Median departure delay | {basic['median']:.1f} min |
| 90th percentile | {basic['p90']:.1f} min |
| Departed early (< 0 min) | {100*basic['early']/n:.1f}% |
| Departed at least 15 min late | {100*basic['late15']/n:.1f}% |

![Distribution of departure delays](reports/figures/delay_distribution.png)

The chart uses two-minute bins from −30 to under 120 minutes, with percentages calculated over all eligible flights. The unplotted tails contain {basic['below_window']:,} flights below −30 minutes ({100*basic['below_window']/n:.3f}%) and {basic['above_window']:,} flights at 120 minutes or more ({100*basic['above_window']/n:.2f}%). These flights remain included in the summary statistics and dataset.

![Mean departure delay by scheduled local hour](reports/figures/delay_by_hour.png)

Hours with fewer than 1,000 flights are omitted from the plot; the remaining overnight hours also have fewer flights than daytime hours.

![Monthly mean departure delay](reports/figures/delay_by_month.png)

| Year | Scheduled flights in master | Cancelled | Eligible flights | Mean delay (min) | Median delay (min) | ≥15 min late |
|---|---:|---:|---:|---:|---:|---:|
'''
    for r in yearly.to_dicts():content+=f"| {r['year']} | {r['scheduled']:,} | {r['cancelled']:,} ({100*r['cancelled']/r['scheduled']:.1f}%) | {r['eligible']:,} | {r['mean']:.1f} | {r['median']:.1f} | {100*r['late_rate']:.1f}% |\n"
    content+='\n**Five busiest origin airports in the eligible sample**\n\n| Origin | Eligible departures | Mean delay (min) | ≥15 min late |\n|---|---:|---:|---:|\n'
    for r in airport.to_dicts():content+=f"| {r['Origin']} | {r['n']:,} | {r['mean']:.1f} | {100*r['late_rate']:.1f}% |\n"
    content+='''
The master covers BTS reporting-carrier flights, not every flight. The modeling subset excludes cancellations and records without a clock-consistent delay; exclusions may affect these summaries. Flight mix, routes, and weather differ across airports and hours. Regenerate these figures and tables with `.venv/bin/python src/create_summary.py` (requires the local Parquet data).\n'''+END
    readme=ROOT/'README.md'; text=readme.read_text()
    if START in text:
        left,right=text.split(START,1);_,right=right.split(END,1);text=left+content+right
    else:
        marker='## Earlier smoke test';text=text.replace(marker,content+'\n\n'+marker,1)
    readme.write_text(text)
    print('Summary generated for',f'{n:,}','eligible flights')
if __name__=='__main__':main()
