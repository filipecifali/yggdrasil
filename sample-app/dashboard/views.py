import json
import logging
from django.shortcuts import render
from django.http import JsonResponse, HttpResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods
from django.core.cache import cache
from .models import DiagnosticRun, ServiceCheck, S3DiagnosticFile
from .tasks import run_system_diagnostics

logger = logging.getLogger(__name__)


def dashboard_view(request):
    """Renders the Real-time Integration & Diagnostics Dashboard."""
    recent_runs = DiagnosticRun.objects.prefetch_related('checks', 's3_files')[:10]
    latest_run = recent_runs[0] if recent_runs else None

    # Retrieve live cached metrics from Redis
    cached_latest = cache.get('latest_diagnostic_run')

    context = {
        'recent_runs': recent_runs,
        'latest_run': latest_run,
        'cached_latest': cached_latest,
        'app_version': '1.0.0',
    }
    return render(request, 'dashboard/index.html', context)


@csrf_exempt
@require_http_methods(["POST"])
def api_run_diagnostics(request):
    """
    Triggers an asynchronous full-stack diagnostic run via Celery over RabbitMQ.
    Returns the newly created run ID immediately (non-blocking).
    """
    run = DiagnosticRun.objects.create(status='PENDING')
    task = run_system_diagnostics.delay(str(run.id))
    run.celery_task_id = task.id
    run.save(update_fields=['celery_task_id'])

    return JsonResponse({
        'status': 'TRIGGERED',
        'run_id': str(run.id),
        'celery_task_id': task.id,
        'message': 'Diagnostic task queued via RabbitMQ to Celery worker.'
    }, status=202)


@require_http_methods(["GET"])
def api_run_status(request, run_id):
    """Returns the JSON state of a specific diagnostic run."""
    try:
        run = DiagnosticRun.objects.prefetch_related('checks', 's3_files').get(id=run_id)
        checks = [
            {
                'service': c.service_name,
                'status': c.status,
                'latency_ms': c.latency_ms,
                'details': c.details,
            }
            for c in run.checks.all()
        ]
        files = [
            {
                'name': f.file_name,
                'bucket': f.bucket_name,
                'size_bytes': f.file_size_bytes,
                'etag': f.etag,
            }
            for f in run.s3_files.all()
        ]
        return JsonResponse({
            'run_id': str(run.id),
            'status': run.status,
            'triggered_at': run.triggered_at.isoformat(),
            'completed_at': run.completed_at.isoformat() if run.completed_at else None,
            'overall_latency_ms': run.overall_latency_ms,
            'checks': checks,
            'files': files,
        })
    except DiagnosticRun.DoesNotExist:
        return JsonResponse({'error': 'Run not found'}, status=404)


@require_http_methods(["GET"])
def api_latest_metrics(request):
    """Returns summary metrics for Prometheus / live dashboard polling."""
    total_runs = DiagnosticRun.objects.count()
    successful_runs = DiagnosticRun.objects.filter(status='SUCCESS').count()
    failed_runs = DiagnosticRun.objects.filter(status='FAILED').count()
    cached = cache.get('latest_diagnostic_run')

    return JsonResponse({
        'app': 'sample-app-django',
        'version': '1.0.0',
        'total_runs': total_runs,
        'successful_runs': successful_runs,
        'failed_runs': failed_runs,
        'success_rate_percent': round((successful_runs / total_runs * 100), 1) if total_runs > 0 else 100.0,
        'cached_latest': cached,
    })


def healthz(request):
    """Kubernetes Liveness Probe endpoint."""
    return HttpResponse("OK", content_type="text/plain")


def readyz(request):
    """Kubernetes Readiness Probe endpoint."""
    # Verify minimal DB and cache connectivity
    try:
        from django.db import connection
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1;")
        return HttpResponse("READY", content_type="text/plain")
    except Exception as e:
        logger.warning(f"Readiness check failed: {e}")
        return HttpResponse(f"NOT_READY: {e}", status=503, content_type="text/plain")
