(() => {
function fail(reason) {
  // Thrown from the original source: the console location should map here.
  throw new Error('Ошибка из util.js: ' + reason);
}

function greet(name) {
  return 'Привет, ' + name;
}


console.log(greet('бандл'), 'из src/app.js');

document.getElementById('bundle-fail').addEventListener('click', () => {
  fail('кнопка «Ошибка из бандла»');
});
})();
//# sourceMappingURL=app.js.map
