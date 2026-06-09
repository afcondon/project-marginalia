// FFI for API.Subscriptions
// JSON response builders for the Finance section.

export const buildSubscriptionListJson = (rows) => {
  const subscriptions = (rows || []).map(row => ({
    id: Number(row.id),
    name: row.name,
    category: row.category || null,
    amount: row.amount != null ? Number(row.amount) : null,
    currency: row.currency || 'EUR',
    frequency: row.frequency || 'monthly',
    nextDue: row.next_due || null,
    autoRenew: row.auto_renew != null ? Boolean(row.auto_renew) : true,
    cancelUrl: row.cancel_url || null,
    notes: row.notes || null,
    projectId: row.project_id != null ? Number(row.project_id) : null,
    active: row.active != null ? Boolean(row.active) : true,
    createdAt: row.created_at || null,
    updatedAt: row.updated_at || null,
  }));

  // Compute summary stats for the Finance section header
  const monthlyBurn = subscriptions
    .filter(s => s.active && s.amount != null)
    .reduce((sum, s) => {
      switch (s.frequency) {
        case 'weekly':      return sum + s.amount * 4.33;
        case 'fortnightly': return sum + s.amount * 26 / 12;  // 26 fortnights/yr
        case 'monthly':     return sum + s.amount;
        case 'quarterly':   return sum + s.amount / 3;
        case 'annual':      return sum + s.amount / 12;
        default:            return sum + s.amount;
      }
    }, 0);

  return JSON.stringify({
    subscriptions,
    count: subscriptions.length,
    monthlyBurn: Math.round(monthlyBurn * 100) / 100,
  });
};

export const buildSubscriptionDetailJson = (row) => {
  return JSON.stringify({
    id: Number(row.id),
    name: row.name,
    category: row.category || null,
    amount: row.amount != null ? Number(row.amount) : null,
    currency: row.currency || 'EUR',
    frequency: row.frequency || 'monthly',
    nextDue: row.next_due || null,
    autoRenew: row.auto_renew != null ? Boolean(row.auto_renew) : true,
    cancelUrl: row.cancel_url || null,
    notes: row.notes || null,
    projectId: row.project_id != null ? Number(row.project_id) : null,
    active: row.active != null ? Boolean(row.active) : true,
    createdAt: row.created_at || null,
    updatedAt: row.updated_at || null,
  });
};
