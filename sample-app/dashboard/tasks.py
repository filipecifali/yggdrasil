import time
import json
import logging
from celery import shared_task
from django.utils import timezone
from django.core.cache import cache
from django.db import connection
from django.conf import settings
from .models import DiagnosticRun, ServiceCheck, S3DiagnosticFile

logger = logging.getLogger(__name__)


@shared_task(bind=True, name='dashboard.run_system_diagnostics')
def run_system_diagnostics(self, run_id_str):
    """
    Executes end-to-end diagnostics across PostgreSQL, Redis, RabbitMQ, and SeaweedFS S3.
    Dispatched via RabbitMQ broker and executed inside Celery worker container.
    """
    start_total = time.time()
    try:
        run = DiagnosticRun.objects.get(id=run_id_str)
    except DiagnosticRun.DoesNotExist:
        logger.error(f"DiagnosticRun {run_id_str} not found")
        return {"error": "Run not found"}

    run.status = 'RUNNING'
    run.celery_task_id = self.request.id
    run.save(update_fields=['status', 'celery_task_id'])

    results = {}
    all_passed = True

    # --------------------------------------------------------------------------
    # 1. POSTGRESQL VERIFICATION
    # --------------------------------------------------------------------------
    t0 = time.time()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1 as ping, current_database(), version();")
            row = cursor.fetchone()
            db_name = row[1]
            pg_version = row[2].split()[0] + " " + row[2].split()[1]
        lat_pg = (time.time() - t0) * 1000
        ServiceCheck.objects.create(
            run=run,
            service_name='postgres',
            status='PASS',
            latency_ms=round(lat_pg, 2),
            details=f"Connected to DB '{db_name}' ({pg_version}). Query SELECT 1 successful."
        )
        results['postgres'] = {'status': 'PASS', 'latency_ms': round(lat_pg, 2)}
    except Exception as e:
        lat_pg = (time.time() - t0) * 1000
        all_passed = False
        ServiceCheck.objects.create(
            run=run,
            service_name='postgres',
            status='FAIL',
            latency_ms=round(lat_pg, 2),
            details=f"PostgreSQL query error: {str(e)}"
        )
        results['postgres'] = {'status': 'FAIL', 'error': str(e)}

    # --------------------------------------------------------------------------
    # 2. REDIS CACHE VERIFICATION
    # --------------------------------------------------------------------------
    t0 = time.time()
    try:
        test_key = f"diag:test:{run.id}"
        test_val = {"run_id": str(run.id), "timestamp": time.time()}
        cache.set(test_key, test_val, timeout=60)
        retrieved_val = cache.get(test_key)
        assert retrieved_val == test_val, "Cached payload mismatch"
        cache.delete(test_key)
        lat_redis = (time.time() - t0) * 1000
        ServiceCheck.objects.create(
            run=run,
            service_name='redis',
            status='PASS',
            latency_ms=round(lat_redis, 2),
            details=f"SET/GET/DELETE cycle passed on key '{test_key}'. In-memory cache valid."
        )
        results['redis'] = {'status': 'PASS', 'latency_ms': round(lat_redis, 2)}
    except Exception as e:
        lat_redis = (time.time() - t0) * 1000
        all_passed = False
        ServiceCheck.objects.create(
            run=run,
            service_name='redis',
            status='FAIL',
            latency_ms=round(lat_redis, 2),
            details=f"Redis error: {str(e)}"
        )
        results['redis'] = {'status': 'FAIL', 'error': str(e)}

    # --------------------------------------------------------------------------
    # 3. RABBITMQ BROKER VERIFICATION
    # --------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Since this Celery task is currently executing, the RabbitMQ broker
        # already successfully dispatched this task through the AMQP exchange and queue!
        broker_url_masked = settings.CELERY_BROKER_URL.split('@')[-1] if '@' in settings.CELERY_BROKER_URL else 'localhost'
        lat_rmq = (time.time() - t0) * 1000
        ServiceCheck.objects.create(
            run=run,
            service_name='rabbitmq',
            status='PASS',
            latency_ms=round(lat_rmq, 2),
            details=f"Task delivered via RabbitMQ broker '{broker_url_masked}' to Celery worker."
        )
        results['rabbitmq'] = {'status': 'PASS', 'latency_ms': round(lat_rmq, 2)}
    except Exception as e:
        lat_rmq = (time.time() - t0) * 1000
        all_passed = False
        ServiceCheck.objects.create(
            run=run,
            service_name='rabbitmq',
            status='FAIL',
            latency_ms=round(lat_rmq, 2),
            details=f"RabbitMQ check error: {str(e)}"
        )
        results['rabbitmq'] = {'status': 'FAIL', 'error': str(e)}

    # --------------------------------------------------------------------------
    # 4. SEAWEEDFS S3 OBJECT STORAGE VERIFICATION
    # --------------------------------------------------------------------------
    t0 = time.time()
    try:
        import boto3
        from botocore.config import Config
        from botocore.exceptions import ClientError

        s3_client = boto3.client(
            's3',
            endpoint_url=getattr(settings, 'AWS_S3_ENDPOINT_URL', 'http://seaweedfs-s3.storage-system.svc.cluster.local:8333'),
            aws_access_key_id=getattr(settings, 'AWS_ACCESS_KEY_ID', 'admin'),
            aws_secret_access_key=getattr(settings, 'AWS_SECRET_ACCESS_KEY', 'ChangeMe123!'),
            config=Config(signature_version='s3v4', s3={'addressing_style': 'path'}),
            verify=getattr(settings, 'AWS_S3_VERIFY', False)
        )

        bucket_name = getattr(settings, 'AWS_STORAGE_BUCKET_NAME', 'sample-app-demo')
        # Ensure bucket exists
        try:
            s3_client.head_bucket(Bucket=bucket_name)
        except ClientError:
            try:
                s3_client.create_bucket(Bucket=bucket_name)
            except Exception:
                pass

        file_key = f"diagnostics/run_{run.id}.json"
        payload = json.dumps({
            "run_id": str(run.id),
            "triggered_at": run.triggered_at.isoformat(),
            "status": "VALIDATION_SAMPLE",
            "cluster": "yggdrasil-sovereign",
        }).encode('utf-8')

        # Put object
        put_resp = s3_client.put_object(
            Bucket=bucket_name,
            Key=file_key,
            Body=payload,
            ContentType='application/json'
        )
        etag = put_resp.get('ETag', '').strip('"')

        # Read object back
        get_resp = s3_client.get_object(Bucket=bucket_name, Key=file_key)
        data = get_resp['Body'].read()
        assert data == payload, "S3 payload validation mismatch"

        lat_s3 = (time.time() - t0) * 1000

        # Record file metadata in Postgres
        S3DiagnosticFile.objects.create(
            run=run,
            file_name=f"run_{run.id}.json",
            s3_key=file_key,
            bucket_name=bucket_name,
            file_size_bytes=len(payload),
            etag=etag
        )

        ServiceCheck.objects.create(
            run=run,
            service_name='seaweedfs',
            status='PASS',
            latency_ms=round(lat_s3, 2),
            details=f"Wrote & read s3://{bucket_name}/{file_key} ({len(payload)} bytes, ETag: {etag[:8]}...)."
        )
        results['seaweedfs'] = {'status': 'PASS', 'latency_ms': round(lat_s3, 2)}
    except Exception as e:
        lat_s3 = (time.time() - t0) * 1000
        all_passed = False
        ServiceCheck.objects.create(
            run=run,
            service_name='seaweedfs',
            status='FAIL',
            latency_ms=round(lat_s3, 2),
            details=f"SeaweedFS S3 error: {str(e)}"
        )
        results['seaweedfs'] = {'status': 'FAIL', 'error': str(e)}

    # --------------------------------------------------------------------------
    # FINALIZE RUN
    # --------------------------------------------------------------------------
    total_duration_ms = (time.time() - start_total) * 1000
    run.completed_at = timezone.now()
    run.status = 'SUCCESS' if all_passed else 'FAILED'
    run.overall_latency_ms = round(total_duration_ms, 2)
    run.summary = json.dumps(results)
    run.save(update_fields=['completed_at', 'status', 'overall_latency_ms', 'summary'])

    # Cache latest run result in Redis for instant dashboard refresh
    cache.set('latest_diagnostic_run', {
        'id': str(run.id),
        'status': run.status,
        'latency_ms': run.overall_latency_ms,
        'results': results,
        'completed_at': run.completed_at.isoformat()
    }, timeout=3600)

    logger.info(f"DiagnosticRun {run.id} finished with status {run.status} in {total_duration_ms:.2f} ms")
    return {"status": run.status, "duration_ms": total_duration_ms, "results": results}
