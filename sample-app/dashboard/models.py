import uuid
from django.db import models
from django.utils import timezone


class DiagnosticRun(models.Model):
    STATUS_CHOICES = [
        ('PENDING', 'Pending'),
        ('RUNNING', 'Running'),
        ('SUCCESS', 'Success'),
        ('FAILED', 'Failed'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    triggered_at = models.DateTimeField(default=timezone.now)
    completed_at = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='PENDING')
    celery_task_id = models.CharField(max_length=255, blank=True, null=True)
    overall_latency_ms = models.FloatField(default=0.0)
    summary = models.TextField(blank=True, default='')

    class Meta:
        ordering = ['-triggered_at']

    def __str__(self):
        return f"Run {self.id} [{self.status}] at {self.triggered_at.strftime('%Y-%m-%d %H:%M:%S')}"


class ServiceCheck(models.Model):
    SERVICE_CHOICES = [
        ('postgres', 'PostgreSQL Database'),
        ('redis', 'Redis In-Memory Cache'),
        ('rabbitmq', 'RabbitMQ Message Broker'),
        ('seaweedfs', 'SeaweedFS S3 Object Storage'),
    ]
    STATUS_CHOICES = [
        ('PASS', 'Pass'),
        ('FAIL', 'Fail'),
    ]

    run = models.ForeignKey(DiagnosticRun, on_delete=models.CASCADE, related_name='checks')
    service_name = models.CharField(max_length=50, choices=SERVICE_CHOICES)
    status = models.CharField(max_length=10, choices=STATUS_CHOICES)
    latency_ms = models.FloatField(default=0.0)
    details = models.TextField(blank=True, default='')
    checked_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ['run', 'service_name']

    def __str__(self):
        return f"{self.service_name}: {self.status} ({self.latency_ms:.2f} ms)"


class S3DiagnosticFile(models.Model):
    run = models.ForeignKey(DiagnosticRun, on_delete=models.CASCADE, related_name='s3_files')
    file_name = models.CharField(max_length=255)
    s3_key = models.CharField(max_length=512)
    bucket_name = models.CharField(max_length=100)
    file_size_bytes = models.IntegerField(default=0)
    etag = models.CharField(max_length=100, blank=True, default='')
    created_at = models.DateTimeField(default=timezone.now)

    def __str__(self):
        return f"{self.file_name} ({self.file_size_bytes} bytes in {self.bucket_name})"
