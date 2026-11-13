from django.urls import path
from . import views

app_name = 'dashboard'

urlpatterns = [
    path('', views.dashboard_view, name='index'),
    path('api/diagnostics/run', views.api_run_diagnostics, name='api_run'),
    path('api/diagnostics/<uuid:run_id>', views.api_run_status, name='api_status'),
    path('api/metrics', views.api_latest_metrics, name='api_metrics'),
    path('healthz', views.healthz, name='healthz'),
    path('readyz', views.readyz, name='readyz'),
]
