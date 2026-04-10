// FFI for Finance.App

export const parseSubscriptions_ = (str) => {
  try {
    const d = JSON.parse(str);
    return {
      subscriptions: (d.subscriptions || []).map(s => ({
        id: s.id || 0,
        name: s.name || '',
        category: s.category || '',
        amount: s.amount || 0,
        currency: s.currency || 'EUR',
        frequency: s.frequency || 'monthly',
        nextDue: s.nextDue || '',
        notes: s.notes || '',
      })),
      monthlyBurn: d.monthlyBurn || 0,
    };
  } catch {
    return { subscriptions: [], monthlyBurn: 0 };
  }
};
