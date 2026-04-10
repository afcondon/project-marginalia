// FFI for API.Exercise

export const buildExerciseListJson = (rows) => {
  const entries = (rows || []).map(row => ({
    id: Number(row.id),
    activity: row.activity,
    date: row.date || null,
    duration: row.duration != null ? Number(row.duration) : null,
    distance: row.distance != null ? Number(row.distance) : null,
    calories: row.calories != null ? Number(row.calories) : null,
    notes: row.notes || null,
    source: row.source || 'manual',
  }));
  return JSON.stringify({ entries, count: entries.length });
};

export const buildExerciseSummaryJson = (rows) => {
  // Transform rows into { activity -> { "YYYY-MM" -> { sessions, minutes } } }
  const byActivity = {};
  for (const row of (rows || [])) {
    const act = row.activity;
    const key = `${row.year}-${String(row.month).padStart(2, '0')}`;
    if (!byActivity[act]) byActivity[act] = {};
    byActivity[act][key] = {
      sessions: Number(row.sessions),
      minutes: Number(row.total_minutes),
    };
  }

  // Build ordered month keys for the last 12 months
  const now = new Date();
  const months = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    months.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`);
  }

  // Build summary array: one entry per activity with 12-month session counts
  const activities = Object.keys(byActivity).sort();
  const summary = activities.map(act => ({
    activity: act,
    months: months.map(m => {
      const entry = byActivity[act]?.[m];
      return {
        month: m,
        sessions: entry?.sessions || 0,
        minutes: entry?.minutes || 0,
      };
    }),
    totalSessions: Object.values(byActivity[act]).reduce((s, e) => s + e.sessions, 0),
    totalMinutes: Object.values(byActivity[act]).reduce((s, e) => s + e.minutes, 0),
  }));

  return JSON.stringify({ summary, months, activities });
};
