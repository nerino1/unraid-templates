<?php
$rc_script    = '/etc/rc.d/rc.idrac-fan-controller';
$pid_file     = '/var/run/idrac-fan-controller.pid';
$override_file= '/mnt/user/appdata/idrac-fan-controller/fan_override';

header('Content-Type: application/json');

$action = $_POST['action'] ?? $_GET['action'] ?? '';

switch ($action) {
  case 'start':
    exec("nohup $rc_script start > /tmp/idrac-start.log 2>&1 &");
    sleep(2);
    echo json_encode(['ok' => true, 'status' => getStatus()]);
    break;

  case 'stop':
    exec("$rc_script stop > /tmp/idrac-stop.log 2>&1");
    sleep(1);
    echo json_encode(['ok' => true, 'status' => getStatus()]);
    break;

  case 'restart':
    exec("nohup $rc_script restart > /tmp/idrac-restart.log 2>&1 &");
    sleep(3);
    echo json_encode(['ok' => true, 'status' => getStatus()]);
    break;

  case 'status':
    echo json_encode(['ok' => true, 'status' => getStatus()]);
    break;

  case 'enable_override':
    $speed = intval($_POST['speed'] ?? 50);
    file_put_contents($override_file, $speed);
    echo json_encode(['ok' => true, 'override_active' => true]);
    break;

  case 'disable_override':
    if (file_exists($override_file)) unlink($override_file);
    echo json_encode(['ok' => true, 'override_active' => false]);
    break;

  default:
    echo json_encode(['ok' => false, 'error' => 'unknown action']);
}

function getStatus() {
  global $pid_file;
  if (!file_exists($pid_file)) return 'stopped';
  $pid = trim(file_get_contents($pid_file));
  if ($pid && file_exists("/proc/$pid")) return 'running';
  return 'stopped';
}
