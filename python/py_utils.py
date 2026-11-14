from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.optimize import curve_fit, minimize
from scipy.special import betaln, gammaln
from scipy.stats import chi2 as chi2_dist
from IPython.display import display


def directories(data_str, fig_str, out_str, csv_str):
    """Data, figures and output folders (the last two are created if
    missing) and the path of the input csv inside the data folder."""
    fig_dir = Path(fig_str)
    data_dir = Path(data_str)
    fig_dir.mkdir(exist_ok=True)
    out_dir = Path(out_str)
    out_dir.mkdir(exist_ok=True)
    return data_dir, fig_dir, out_dir, data_dir/csv_str


def print_df(df):
    """Shape, column types and a random sample of 20 rows (fixed seed)."""
    print("Clean retail data:")
    print(df.shape)
    print(df.dtypes)
    display(df.sample(20, random_state=0))


def save_show_graph(fig, folder, name):
    """Save the figure in folder/name (150 dpi) and show it."""
    fig.tight_layout()
    fig.savefig(folder/name, dpi=150)
    plt.show()


def pareto_table(revenues):
    """Items sorted by decreasing revenue, with each item's share of revenue
    and the cumulative shares of items and revenue (the Pareto curve)."""
    sort = revenues.sort_values(ascending=False)
    table = pd.DataFrame({"revenue": sort})
    table["rank"] = np.arange(1, len(sort) + 1)
    table["rev_relative"] = sort / sort.sum()
    table["cum_items"] = table["rank"] / len(sort)
    table["cum_rev_relative"] = table["rev_relative"].cumsum()
    return table


def pareto_summary(table, label, top_pct, rev_target_pct):
    """Revenue share of the top top_pct% items, and how many items are
    needed to reach rev_target_pct% of revenue."""
    n = len(table)
    n_top = int(np.ceil(n * top_pct/100))
    rev_top = table["cum_rev_relative"].iloc[n_top - 1]
    n_target = np.searchsorted(table["cum_rev_relative"].to_numpy(),
                               rev_target_pct/100) + 1
    return {
        "group": label,
        "items": n,
        f"top_{top_pct}pct_items": n_top,
        f"top_{top_pct}pct_cum_rev": round(100*rev_top, 1),
        f"count_for_{rev_target_pct}pct_rev": n_target,
        f"pct_items_for_{rev_target_pct}pct_rev":
            round(100*n_target/n, 1),
    }


def top_items(r, top_pct):
    """Set of the top top_pct% items (customers or products) by revenue
    (r: revenue per item)."""
    r = r.sort_values(ascending=False)
    return set(r.index[: int(np.ceil(len(r)*top_pct/100))])


def month_label(i):
    """Month index (year*12 + month) to 'YYYY-MM'."""
    return f"{(i - 1)//12}-{(i - 1)%12 + 1:02d}"


def cohort_activity(lines):
    """Active customers per cohort (month of first purchase, as year*12 +
    month) and period (months since it). Cells after the end of the data
    cannot be observed: they are NaN, and periods never observed are dropped."""
    c = lines[["customer_id"]].assign(month_idx=lines["invoice_date"].dt.year*12
                                      + lines["invoice_date"].dt.month)
    c = c.drop_duplicates()
    c["cohort_idx"] = c.groupby("customer_id")["month_idx"].transform("min")
    c["period"] = c["month_idx"] - c["cohort_idx"]
    active = c.groupby(["cohort_idx", "period"])["customer_id"].nunique().unstack(fill_value=0)
    max_period = c["month_idx"].max() - active.index.to_numpy()
    active = active.mask(active.columns.to_numpy()[None, :] > max_period[:, None])
    return active.dropna(axis=1, how="all")


def retention_tables(active_cust):
    """Retention matrix, size-weighted average retention, number of observed
    cohorts per period and cohort size (period 0). Rows get 'YYYY-MM' labels."""
    cohort_size = active_cust[0]
    labels = [month_label(i) for i in active_cust.index]
    matrix = 100*active_cust.div(cohort_size, axis=0)
    avg = 100*active_cust.sum() / active_cust.notna().mul(cohort_size, axis=0).sum()
    n_cohorts = active_cust.notna().sum()
    matrix.index = labels
    return matrix, avg, n_cohorts, cohort_size.set_axis(labels)


def price_bands(price, q, labels, right=False):
    """Split products into q quantile bands of price (one row per product).
    Intervals are [a, b) if right is False, (a, b] otherwise; the outer edges
    are open, so every product falls in a band. Returns the band of every
    product and the q - 1 inner edges."""
    edges = price.quantile(np.linspace(0, 1, q + 1)).to_numpy().copy()
    edges[0], edges[-1] = -np.inf, np.inf
    return pd.cut(price, edges, right=right, labels=labels).rename("band"), edges[1:-1]


def band_summary(sales, band):
    """Products, units and revenue per price band (all product lines), in
    absolute terms and in %. band: price band of every stock_code."""
    lines = sales.assign(band=sales["stock_code"].map(band))
    by_band = lines.groupby("band", observed=True)
    summary = by_band.agg(products=("stock_code", "nunique"),
                          units=("quantity", "sum"),
                          revenue=("revenue", "sum"))
    summary["avg_price_paid"] = summary["revenue"]/summary["units"]
    summary["median_units_per_line"] = by_band["quantity"].median()
    for col in ["products", "units", "revenue"]:
        summary[f"{col}_pct"] = 100*summary[col]/summary[col].sum()
    return summary


def segment_mix(sales, band, segment):
    """Share of each group's revenue per price band, in %. segment: segment
    of every known customer_key; lines without customer ID form their own
    group, "No customer ID"."""
    group = sales["customer_key"].map(segment).fillna("No customer ID")
    return 100*pd.crosstab(group.rename("segment"), sales["stock_code"].map(band).rename("band"),
                           values=sales["revenue"], aggfunc="sum", normalize="index")


def with_total(table, label="All") -> pd.DataFrame:
    """The table with an extra row of column sums."""
    out = pd.concat([table, table.sum().to_frame(label).T])
    out.index.name = table.index.name
    return out


def same_period_growth(lines, life):
    """Revenue of each product in 2010 and 2011 over the same calendar period:
    from its first sale (life["first_sale"]) in 2010, and from 365 days later
    in 2011 (no leap day in between). lines: product lines of both years."""
    prev, now = same_period_lines(lines, life)
    return pd.DataFrame({
        "revenue_prev_cmp": prev.groupby("stock_code")["revenue"].sum(),
        "revenue_cmp": now.groupby("stock_code")["revenue"].sum(),
    })


def same_period_lines(lines, life):
    """The lines of same_period_growth: those of 2010, and those of 2011 from
    365 days after the product's first sale."""
    cmp_start = lines["stock_code"].map(life["first_sale"])
    in_prev = lines["year"] == 2010
    in_now = (lines["year"] == 2011) & (lines["invoice_date"] >= cmp_start + pd.Timedelta(days=365))
    return lines[in_prev], lines[in_now]


def revenue_factors(lines, group):
    """Per group: revenue, buyers (customer-product pairs), lines per buyer,
    units per line and revenue per unit; revenue is the product of the last
    four. group: a label per line (a Series aligned with lines)."""
    g = lines.groupby(group, observed=True)
    buyers = (lines.drop_duplicates(["stock_code", "customer_key"])
              .groupby(group, observed=True).size())
    revenue, n_lines, units = g["revenue"].sum(), g.size(), g["quantity"].sum()
    return pd.DataFrame({"revenue": revenue, "buyers": buyers,
                         "lines_per_buyer": n_lines/buyers, "units_per_line": units/n_lines,
                         "revenue_per_unit": revenue/units})


def revenue_decomposition(prev, now, group):
    """Change (%) of revenue and of each of its four factors (revenue_factors)
    from the lines prev to the lines now, per group; since revenue is their
    product, 1 + change of revenue = product of (1 + change of each factor)."""
    a = revenue_factors(prev, group.reindex(prev.index))
    b = revenue_factors(now, group.reindex(now.index))
    return 100*(b/a - 1)


def product_stats(lines, segment):
    """Per product: invoices, units, revenue and known customers over lines;
    customers of the "Core loyal" segment (segment: segment of every
    customer_key); share of revenue (%) from the largest known customer."""
    out = lines.groupby("stock_code").agg(invoices_12m=("invoice", "nunique"),
                                          units_12m=("quantity", "sum"),
                                          revenue_12m=("revenue", "sum"),
                                          customers_12m=("customer_id", "nunique"))
    core = lines[lines["customer_key"].map(segment) == "Core loyal"]
    out["core_customers_12m"] = core.groupby("stock_code")["customer_key"].nunique()
    cust_rev = (lines[lines["is_missing_customer"] == 0]
                .groupby(["stock_code", "customer_key"])["revenue"].sum())
    out["top_customer_pct"] = 100*cust_rev.groupby(level=0).max()/out["revenue_12m"]
    return (out.fillna({"core_customers_12m": 0, "top_customer_pct": 0})
            .astype({"core_customers_12m": int}))


def top_flag_by_group(values, group, top_pct=20):
    """True for the items at or above the (100 - top_pct)% quantile of values
    within their group."""
    threshold = values.groupby(group, observed=True).transform(
        lambda v: v.quantile(1 - top_pct/100))
    return values >= threshold


def short_action(actions):
    """Action name without its reason: "Invest: broad base, growing" -> "Invest"."""
    return actions.str.split(":").str[0]


def action_counts(variants):
    """Items per action (short names) for each variant: one row per variant.
    variants: {name: Series of actions}."""
    return (pd.DataFrame({name: short_action(a).value_counts() for name, a in variants.items()})
            .fillna(0).astype(int).T)


def worst_growth(products, first_sale_limit, share=0.25):
    """Growth (%) that marks the worst `share` of the products whose growth is
    measurable (first sold before first_sale_limit): the first quartile."""
    measurable = products["first_sale"] < first_sale_limit
    return products.loc[measurable, "growth_pct"].quantile(share)


def product_actions(products, catalogue_growth, max_top_customer, first_sale_limit, worst=None):
    """Action for each product, from its growth and the breadth of its
    customer base (broad: the largest customer brings less than
    max_top_customer % of the revenue). Growth is measurable for products
    first sold before first_sale_limit, and is compared with 0, with the
    decline of the catalogue and with the worst quartile of all products
    (worst: its threshold, computed here if not given)."""
    broad = products["top_customer_pct"] < max_top_customer
    measurable = products["first_sale"] < first_sale_limit
    growth = products["growth_pct"]
    if worst is None:
        worst = worst_growth(products, first_sale_limit)
    return pd.Series(np.select(
        [~measurable,
         broad & (growth > 0), ~broad & (growth > 0),
         broad & (growth <= worst), ~broad & (growth <= worst),
         broad & (growth <= catalogue_growth), ~broad & (growth <= catalogue_growth)],
        ["Wait: too new to measure growth",
         "Invest: broad base, growing",
         "Broaden: growing, narrow customer base",
         "Investigate: broad base, in the worst quarter of declines",
         "Check customer: narrow base, in the worst quarter of declines",
         "Refresh: broad base, declining faster than the catalogue",
         "Review: narrow base, declining faster than the catalogue"],
        default="No action: declining less than the catalogue"), index=products.index)


def growth_pct(now, before):
    """Percentage growth from before to now."""
    return 100*(now/before - 1)


def buying_rhythm(lines, ref_date):
    """Per customer: number of invoices, days since the last purchase at
    ref_date, and mean gap in days between orders, (last - first purchase)
    / (invoices - 1). The gap is undefined (NaN) for a single invoice or
    when all invoices fall on the same day. Also the first and last purchase."""
    out = lines.groupby("customer_key").agg(frequency=("invoice", "nunique"),
                                            first=("invoice_date", "min"),
                                            last=("invoice_date", "max"))
    span = (out["last"] - out["first"]).dt.days
    gaps = out["frequency"] - 1
    out["recency"] = (ref_date - out["last"]).dt.days
    out["mean_gap"] = (span/gaps).where((gaps > 0) & (span > 0))
    return out[["recency", "frequency", "mean_gap", "first", "last"]]


def customer_actions(rfm, is_overdue, is_lost, sil_vs_core, sil_vs_lost, sil_max, min_value):
    """Action for each customer. Protect: core loyal, overdue, monetary >=
    min_value. Win back: lapsing regular, probably lost (is_lost), monetary >=
    min_value. Retain / Upgrade: recent occasional with silhouette below
    sil_max towards lost one-timers / core loyal (Retain wins if both).
    Everyone else: No action."""
    seg = rfm["segment"]
    recent = seg == "Recent occasional"
    valuable = rfm["monetary"] >= min_value
    return pd.Series(np.select(
        [(seg == "Core loyal") & is_overdue & valuable,
         (seg == "Lapsing regulars") & is_lost & valuable,
         recent & (sil_vs_lost < sil_max),
         recent & (sil_vs_core < sil_max)],
        ["Protect: core customer, overdue",
         "Win back: lapsing, probably lost",
         "Retain: recent, slipping towards lost",
         "Upgrade: recent, close to core"],
        default="No action"), index=rfm.index)


def bgnbd_inputs(lines, ref_date):
    """BG/NBD summary per customer, on purchase days and in weeks: x = repeat
    purchase days, t_x = last purchase day from the first, T = ref_date from
    the first purchase day."""
    days = lines["invoice_date"].dt.normalize().groupby(lines["customer_key"])
    first = days.min()
    return pd.DataFrame({"x": days.nunique() - 1, "t_x": (days.max() - first).dt.days/7,
                         "T": (ref_date - first).dt.days/7})


def bgnbd_fit(data):
    """Maximum likelihood estimate of the BG/NBD parameters (r, alpha, a, b)
    (Fader, Hardie and Lee, 2005): while active, each customer buys as a
    Poisson process with rate ~ Gamma(r, alpha), and after each purchase
    stops for good with probability ~ Beta(a, b)."""
    x, tx, T = data["x"].to_numpy(), data["t_x"].to_numpy(), data["T"].to_numpy()
    def neg_log_lik(log_par):
        r, alpha, a, b = np.exp(log_par)
        common = gammaln(r + x) - gammaln(r) + r*np.log(alpha) - betaln(a, b)
        alive = common + betaln(a, b + x) - (r + x)*np.log(alpha + T)
        dead = np.where(x > 0, common + betaln(a + 1, b + np.maximum(x, 1) - 1)
                        - (r + x)*np.log(alpha + tx), -np.inf)
        return -np.logaddexp(alive, dead).sum()
    res = minimize(neg_log_lik, np.log([0.5, 5, 0.5, 2]), method="Nelder-Mead",
                   options={"maxiter": 20000, "xatol": 1e-8, "fatol": 1e-8})
    if not res.success:
        raise RuntimeError(res.message)
    return pd.Series(np.exp(res.x), index=["r", "alpha", "a", "b"])


def bgnbd_p_alive(data, par):
    """Probability that each customer is still active (BG/NBD)."""
    r, alpha, a, b = par
    x = data["x"]
    odds = np.where(x > 0, a/(b + x - 1)*((alpha + data["T"])/(alpha + data["t_x"]))**(r + x), 0)
    return pd.Series(1/(1 + odds), index=data.index)


def backtest_customers(lines, cutoff, months=6):
    """Customers with a buying rhythm at cutoff (invoices on at least two
    different days before it), with what is known at cutoff: overdue =
    recency / mean gap, and the BG/NBD probability of being still active
    (fitted on all customers before cutoff). Then what happened: invoices in
    the `months` after cutoff (whether they returned) and in the same months
    one year earlier, to compare the same season."""
    before = lines[lines["invoice_date"] < cutoff]
    bt = buying_rhythm(before, cutoff).dropna(subset=["mean_gap"])
    bt["overdue"] = bt["recency"]/bt["mean_gap"]
    data = bgnbd_inputs(before, cutoff)
    bt["p_alive"] = bgnbd_p_alive(data, bgnbd_fit(data)).reindex(bt.index)
    def invoices(start):
        return invoices_between(lines, start, start + pd.DateOffset(months=months), bt.index)
    bt["invoices_next"] = invoices(cutoff)
    bt["invoices_year_before"] = invoices(cutoff - pd.DateOffset(years=1))
    bt["returned"] = bt["invoices_next"] > 0
    return bt


def invoices_between(lines, start, end, customers):
    """Invoices of each customer in [start, end). start and end are dates, or
    Series indexed by customer (one window per customer)."""
    x = lines[lines["customer_key"].isin(customers)]
    per_line = lambda v: x["customer_key"].map(v) if isinstance(v, pd.Series) else v
    inside = (x["invoice_date"] >= per_line(start)) & (x["invoice_date"] < per_line(end))
    return (x[inside].groupby("customer_key")["invoice"].nunique()
            .reindex(customers, fill_value=0))


def weekly_concentration(lines, start, end, top=10):
    """Per full week from start (week 0) to end (excluded), as in weekly_bins:
    customers, revenue (£k), share of the week's revenue from its largest
    customer and from its `top` largest (%), and revenue without them (£k)."""
    x = lines[(lines["invoice_date"] >= start) & (lines["invoice_date"] < end)]
    week = ((x["invoice_date"] - start).dt.days // 7).rename("week")
    cust = x.groupby([week, "customer_key"])["revenue"].sum()
    def one(r):
        r = r.sort_values(ascending=False)
        return pd.Series({"customers": len(r), "revenue_k": r.sum()/1e3,
                          "top1_pct": 100*r.iloc[0]/r.sum(),
                          f"top{top}_pct": 100*r.iloc[:top].sum()/r.sum(),
                          f"without_top{top}_k": r.iloc[top:].sum()/1e3})
    out = cust.groupby(level="week").apply(one).unstack()
    return out.loc[out.index < (end - start).days // 7]


def gauss(t, h, mu, s):
    """Gaussian peak of height h, centre mu and width s (no baseline)."""
    return h*np.exp(-(t - mu)**2/(2*s**2))


def two_gauss(t, h1, mu1, s1, h2, mu2, s2):
    """Sum of two gaussian peaks."""
    return gauss(t, h1, mu1, s1) + gauss(t, h2, mu2, s2)


def weekly_bins(lines, start, end):
    """Per full week from start (week 0) to end (excluded): number of
    purchases (invoices) n, mean and sample SD of the purchase value, and the
    week's total revenue (£k). Weeks without purchases have n = 0, total 0."""
    inv = lines[(lines["invoice_date"] >= start) & (lines["invoice_date"] < end)]
    inv = inv.groupby("invoice").agg(value=("revenue", "sum"), date=("invoice_date", "first"))
    weeks = range((end - start).days // 7)
    by_week = (inv["value"]/1000).groupby((inv["date"] - start).dt.days // 7)
    out = pd.DataFrame({"n": by_week.size(), "mean": by_week.mean(),
                        "sd": by_week.std(ddof=1)}).reindex(weeks)
    out["n"] = out["n"].fillna(0).astype(int)
    out["total"] = (out["n"]*out["mean"]).fillna(0)
    return out


def peak_values(bins, noise_mean, noise_sd):
    """Peak weeks corrected for the noise: total minus the mean of the noise,
    and the error sqrt(noise_sd² + (n * sd/sqrt(n))²), where sd/sqrt(n) is the
    SD of the mean purchase and n times it the SD of the week's total."""
    return pd.DataFrame({"y": bins["total"] - noise_mean,
                         "err": np.hypot(noise_sd, (np.sqrt(bins["n"])*bins["sd"]).fillna(0))})


def noise_level(bins, in_peak):
    """Mean and sample SD of the weekly totals outside the peak weeks."""
    noise = bins.loc[~in_peak, "total"]
    return noise.mean(), noise.std(ddof=1)


def fit_points(pv):
    """Times, values and errors of corrected peak weeks, as arrays for a fit."""
    return pv.index.to_numpy(float), pv["y"].to_numpy(), pv["err"].to_numpy()


def excess_over_noise(lines, start, end, noise_mean, noise_sd):
    """Revenue of the period [start, end) above the noise mean (£k), with its
    error: the noise of the period's weeks, noise_sd * sqrt(days/7), and of
    its purchases, sqrt(n) times their sample SD, added in quadrature."""
    inv = lines[(lines["invoice_date"] >= start) & (lines["invoice_date"] < end)]
    value = inv.groupby("invoice")["revenue"].sum()/1000
    weeks = (end - start).days/7
    return {"weeks": weeks, "purchases": len(value),
            "extra_k": value.sum() - noise_mean*weeks,
            "error_k": np.hypot(noise_sd*np.sqrt(weeks), np.sqrt(len(value))*value.std(ddof=1))}


def fit_peak(model, t, y, err, p0):
    """Weighted least-squares fit of model to y with errors err (taken as
    true errors). Returns the parameters with their standard errors and
    covariance, chi-square, reduced chi-square, its p-value (probability of
    a chi-square at least as large if the model is right), weighted R²
    (weights 1/err²) and the correlation between data and curve."""
    p, cov = curve_fit(model, t, y, p0=p0, sigma=err, absolute_sigma=True, maxfev=100000)
    fit, w = model(t, *p), 1/err**2
    chi2, dof = (((y - fit)/err)**2).sum(), len(y) - len(p)
    y_w = (w*y).sum()/w.sum()
    return {"p": p, "se": np.sqrt(np.diag(cov)), "cov": cov, "k": len(p), "n": len(y),
            "r2_weighted": 1 - (w*(y - fit)**2).sum()/(w*(y - y_w)**2).sum(),
            "chi2": chi2, "dof": dof, "chi2_red": chi2/dof, "p_value": chi2_dist.sf(chi2, dof),
            "corr": np.corrcoef(y, fit)[0, 1]}


def fit_table(fits, cols=("k", "r2_weighted", "chi2", "dof", "chi2_red", "p_value", "corr")):
    """Fit statistics of several fits ({name: fit_peak result}), one row each."""
    return pd.DataFrame({m: {c: f[c] for c in cols} for m, f in fits.items()}).T.astype(float).round(2)


def plus_minus(values, errors, fmt="{:.0f}"):
    """Strings "value ± error"."""
    return [f"{fmt.format(v)} ± {fmt.format(e)}" for v, e in zip(values, errors)]


def peak_regions(grid, curve, share=0.6):
    """Half-height points of a peak curve on a fine grid (first and last
    point at or above half the maximum), and the shortest set of intervals
    holding `share` of its area (the highest part of the curve)."""
    above = grid[curve >= curve.max()/2]
    order = np.argsort(curve)[::-1]
    keep = np.sort(order[:np.searchsorted(np.cumsum(curve[order])/curve.sum(), share) + 1])
    breaks = np.flatnonzero(np.diff(keep) > 1)
    starts, ends = np.r_[keep[0], keep[breaks + 1]], np.r_[keep[breaks], keep[-1]]
    return above.min(), above.max(), list(zip(grid[starts], grid[ends]))


def week_date(start, week):
    """Middle day of week `week` (a number or an array) counted from `start` (week 0)."""
    if np.isscalar(week):
        return start + pd.Timedelta(days=7*week + 3.5)
    return start + pd.to_timedelta(7*np.asarray(week) + 3.5, unit="D")


def masked_share(values, mask, group):
    """Share (%) of each group's total of values that falls where mask is True."""
    return (100*values.where(mask, 0).groupby(group, observed=True).sum()
            / values.groupby(group, observed=True).sum())


def top_by_group(group, revenue, top_items):
    """For each group: items, items in the top set, the group's share of the
    top set and of its revenue (%), and the share of the group's items that
    are in the top set (%). group and revenue are indexed by item."""
    t = pd.DataFrame({"group": group, "revenue": revenue,
                      "top": group.index.isin(list(top_items))})
    out = t.groupby("group", observed=True).agg(items=("top", "size"),
                                                top_items=("top", "sum"))
    top_rev = t[t["top"]].groupby("group", observed=True)["revenue"].sum()
    out["pct_of_top"] = 100*out["top_items"]/out["top_items"].sum()
    out["pct_of_top_revenue"] = (100*top_rev/top_rev.sum()).reindex(out.index, fill_value=0)
    out["pct_of_group_in_top"] = 100*out["top_items"]/out["items"]
    return out.rename_axis(group.name)

