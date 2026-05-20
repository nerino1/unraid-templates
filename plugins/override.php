<?php
$override_file = '/mnt/user/appdata/dell-idrac-fan-controller/logs/fan_override';
header('Content-Type: application/json');
$action = $_POST['action'] ?? '';
if ($action === 'enable_override') {
  $speed = intval($_POST['speed'] ?? 50);
  file_put_contents($override_file, $speed);
  echo json_encode(['ok' => true, 'override_active' => true]);
} elseif ($action === 'disable_override') {
  if (file_exists($override_file)) unlink($override_file);
  echo json_encode(['ok' => true, 'override_active' => false]);
} else {
  echo json_encode(['ok' => false, 'error' => 'unknown action']);
}