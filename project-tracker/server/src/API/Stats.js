// FFI for API.Stats
// JSON builder for the stats endpoint

// Build the complete stats JSON response
// Takes domain_status_counts rows, totals row, and domain list
export const buildStatsJson = (domainStatusRows) => (totalsRows) => (domainRows) => {
  // Totals
  const totals = totalsRows && totalsRows.length > 0 ? totalsRows[0] : {};
  const totalProjects = Number(totals.total_projects) || 0;
  const totalTags = Number(totals.total_tags) || 0;
  const totalDependencies = Number(totals.total_dependencies) || 0;
  const totalNotes = Number(totals.total_notes) || 0;

  // Domain list
  const domains = (domainRows || []).map(r => r.domain);

  // Domain/status breakdown: group by domain
  const byDomain = {};
  for (const row of (domainStatusRows || [])) {
    const domain = row.domain;
    if (!byDomain[domain]) {
      byDomain[domain] = { domain, statuses: {}, total: 0 };
    }
    const count = Number(row.project_count) || 0;
    byDomain[domain].statuses[row.status] = count;
    byDomain[domain].total += count;
  }

  return JSON.stringify({
    totals: {
      projects: totalProjects,
      tags: totalTags,
      dependencies: totalDependencies,
      notes: totalNotes
    },
    domains,
    byDomain: Object.values(byDomain)
  });
};
