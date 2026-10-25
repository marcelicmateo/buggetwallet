package hr.marcelic.budget_wallet

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * Home-screen widget "Safe to spend today" (P13). It shows three words the app gave it and nothing else: the already formatted
 * amount, a status word and the day it was computed, kept in the app-private SharedPreferences file `bw_widget`. No payments, names,
 * merchants, balances or key ever reach this class. Tapping the widget opens the app. Not exported beyond what AppWidget needs
 * (the system sends it the update broadcasts).
 */
class SafeTodayWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        for (id in appWidgetIds) manager.updateAppWidget(id, build(context))
    }

    companion object {
        private const val PREFS = "bw_widget"

        /** Stores the three words (`amount`, `status`, `date`) and redraws every widget on the home screen. */
        fun update(context: Context, amount: String, status: String, date: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("amount", amount).putString("status", status).putString("date", date).apply()
            refresh(context)
        }

        /** Forgets the words: the widget says it is to be set up in the app. */
        fun clear(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
            refresh(context)
        }

        private fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, SafeTodayWidget::class.java))
            if (ids.isEmpty()) return
            manager.updateAppWidget(ids, build(context))
        }

        private fun build(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_safe_today)
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val amount = prefs.getString("amount", null)
            val status = prefs.getString("status", null)
            val date = prefs.getString("date", null)
            val bad = context.getColor(R.color.bw_widget_bad)
            val muted = context.getColor(R.color.bw_widget_muted)
            if (amount.isNullOrEmpty() || status == null) {
                views.setTextViewText(R.id.widget_eyebrow, context.getString(R.string.widget_no_wallet_title))
                views.setTextViewText(R.id.widget_amount, "")
                views.setViewVisibility(R.id.widget_amount, android.view.View.GONE)
                views.setTextViewText(R.id.widget_line, context.getString(R.string.widget_no_wallet_line))
                views.setTextColor(R.id.widget_line, muted)
            } else {
                views.setTextViewText(R.id.widget_eyebrow, context.getString(R.string.widget_eyebrow))
                views.setViewVisibility(R.id.widget_amount, android.view.View.VISIBLE)
                views.setTextViewText(R.id.widget_amount, amount)
                val day = try {
                    if (date == null) null else LocalDate.parse(date)
                } catch (e: Exception) {
                    null
                }
                val stale = day == null || ChronoUnit.DAYS.between(day, LocalDate.now()) > 1
                val line: String
                var worry = false
                if (stale) {
                    line = context.getString(R.string.widget_stale)
                } else {
                    when (status) {
                        "overToday" -> { line = context.getString(R.string.widget_over_today); worry = true }
                        "overBudget" -> { line = context.getString(R.string.widget_over_plan); worry = true }
                        "ended" -> line = context.getString(R.string.widget_ended)
                        else -> line = context.getString(
                            R.string.widget_updated,
                            day!!.format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))
                        )
                    }
                }
                views.setTextViewText(R.id.widget_line, line)
                views.setTextColor(R.id.widget_line, if (worry) bad else muted)
            }
            val open = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            }
            val pending = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.widget_root, pending)
            return views
        }
    }
}
