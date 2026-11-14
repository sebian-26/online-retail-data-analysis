"""
k-medoids clustering - Python port of the clustering phase of my C project
"Cromosomi" (cluster.c), simplified to what this analysis needs.

Algorithm (alternating / Voronoi iteration):
  1. Initial representatives chosen with k-means++ style seeding: each new
     one is drawn with probability proportional to the squared distance from
     the representatives already chosen (a point identical to a chosen one
     has probability 0, so duplicates are never picked together).
  2. Assignment: every point goes to the representative with the lowest
     cost (aggiornaCluster in the C code).
  3. Update: in every cluster, the new representative is the member with the
     lowest total cost towards all other members (aggiornaRappresentanti).
  4. Repeat 2-3 until no representative changes (assegnaAiCluster).
The algorithm always converges, but to a local optimum that depends on the
initial representatives: it is run n_init times and the run with the lowest
total cost is kept.

Ties are broken by index, lowest wins (haPriorita in the C code):
  assignment : (cost, representative index)
  update     : (total cost, member index)

Any cost matrix can be used (e.g. L1 distances), not only Euclidean ones.
"""
import numpy as np

# ---------------------------------------------------------------------
# Steps of the algorithm
# ---------------------------------------------------------------------

def init_medoids(D, k, rng):
    """k-means++ style seeding: k distinct initial representatives."""
    n = D.shape[0]
    chosen = [int(rng.integers(n))]
    for _ in range(k - 1):
        d = D[chosen].min(axis=0)**2
        total = d.sum()
        prob = d / total if total > 0 else None
        chosen.append(int(rng.choice(n, p=prob)))
    return np.array(chosen)


def update_clust(D, medoids):
    """Assignment step (aggiornaCluster): cluster label of every point,
    by (cost, representative index)."""
    n = D.shape[0]
    cost = D[medoids] # (k, n)
    idx = np.repeat(medoids[:, None], n, axis=1)
    return np.lexsort((idx, cost), axis=0)[0]


def update_repr(D, labels, medoids):
    """Update step (aggiornaRappresentanti): new representative of every
    cluster and its total cost towards the members."""
    k = len(medoids)
    new = medoids.copy()
    cost = np.zeros(k)
    for j in range(k):
        members = np.flatnonzero(labels == j) # increasing index
        if members.size == 0:
            continue
        t = D[np.ix_(members, members)].sum(axis=1)
        best = np.lexsort((members, t))[0]
        new[j] = members[best]
        cost[j] = t[best]
    return new, cost


def assign_to_clust(D, medoids):
    """One run (assegnaAiCluster): alternate assignment and update until
    the representatives do not change."""
    while True:
        labels = update_clust(D, medoids)
        new, cost = update_repr(D, labels, medoids)
        unchanged = np.array_equal(new, medoids)
        medoids = new
        if unchanged:
            break
    return dict(medoids=medoids, labels=labels,
                cluster_cost=cost, tot_cost=float(cost.sum()))


# ---------------------------------------------------------------------
# Main interface
# ---------------------------------------------------------------------

def kmedoids(D, k, n_init=10, seed=0):
    """
    D      : (n, n) cost matrix, e.g. scipy cdist(X, X, metric="cityblock").
    k      : number of clusters.
    n_init : number of runs with different initial representatives; the run
             with the lowest total cost is kept.
    seed   : random seed, for reproducible results.

    Returns a dict with:
      medoids       index of the representative of each cluster
      labels        cluster of each point (0 .. k-1)
      cluster_cost  total cost from each representative to its members
      tot_cost      sum over all clusters
    """
    D = np.asarray(D, dtype=np.float64)
    if not 1 <= k <= D.shape[0]:
        raise ValueError("k must be between 1 and the number of points")
    rng = np.random.default_rng(seed)
    best = None
    for _ in range(n_init):
        res = assign_to_clust(D, init_medoids(D, k, rng))
        if best is None or res["tot_cost"] < best["tot_cost"]:
            best = res
    return best

# ---------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------

def mean_dist_to_clusters(D, labels):
    """(n, k) matrix: mean distance of every point from the members of each
    cluster. For the point's own cluster the point itself is excluded, so
    M[i, labels[i]] is a(i) of the silhouette. Labels must be 0 .. k-1.
    One pass over D: compute it once and reuse it for every silhouette."""
    n = len(labels)
    k = labels.max() + 1
    sizes = np.bincount(labels, minlength=k)
    M = np.stack([D[:, labels == c].sum(axis=1) for c in range(k)], axis=1)
    own = sizes[labels] - 1
    M[np.arange(n), labels] /= np.maximum(own, 1)
    others = np.ones_like(M, dtype=bool)
    others[np.arange(n), labels] = False
    M[others] /= np.broadcast_to(sizes, M.shape)[others]
    return M


def silhouette_vs(M, labels, target):
    """Silhouette of every point with respect to a chosen cluster instead of
    the nearest one: (d - a) / max(a, d), with a = mean distance from the own
    cluster and d = mean distance from `target`. Values near 0 or negative
    mean the point is almost as close to `target` as to its own cluster.
    `target` is one cluster id, or one id per point."""
    rows = np.arange(len(labels))
    a = M[rows, labels]
    d = M[rows, target]
    denom = np.maximum(a, d)
    return np.where(denom > 0, (d - a) / np.where(denom > 0, denom, 1), 0.0)


def silhouette_samples(M, labels):
    """Classic silhouette of every point: silhouette_vs with respect to the
    nearest other cluster. Singleton clusters get 0, as in scikit-learn."""
    others = M.copy()
    others[np.arange(len(labels)), labels] = np.inf
    s = silhouette_vs(M, labels, others.argmin(axis=1))
    s[np.bincount(labels)[labels] == 1] = 0.0
    return s


def silhouette(D, labels):
    """Mean silhouette computed directly from the distance matrix."""
    return float(silhouette_samples(mean_dist_to_clusters(D, labels), labels).mean())
