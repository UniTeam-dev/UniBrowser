// Console cases (spec «Консоль»), logged at load: every method, formatting, errors.
console.log('%cСтилизованный%c текст и %s, число %d, объект %o', 'color: #e8833a; font-weight: bold; font-size: 14px', '', 'подстановка', 42.9, { a: 1 });
console.table([{ имя: 'Анна', возраст: 31 }, { имя: 'Борис', возраст: 27, город: 'Казань' }]);
console.table(['a', 'b'], undefined);
console.group('Группа');
console.log('внутри группы');
console.groupCollapsed('Свёрнутая подгруппа');
console.info('внутри свёрнутой');
console.groupEnd();
console.groupEnd();
console.time('таймер');
console.timeEnd('таймер');
console.count();
console.count();
console.count('метка');
console.assert(1 === 2, 'утверждение не выполнено', { ожидалось: 2 });
console.assert(true, 'не должно появиться');
console.dir({ вложенный: { глубоко: { ещё: { дальше: [1, 2, 3] } } }, map: new Map([['k', 1]]), set: new Set([1]) });
console.dirxml(document.documentElement);
for (let i = 0; i < 3; i++) console.log('одинаковое сообщение');
console.log(Symbol('s'), 10n, null, undefined, true, function named() {}, [1, 'два', { три: 3 }], new Error('ошибка как значение'));

function traced() { console.trace('трассировка'); }
traced();

window.consoleTest = {
  throwNow() { throw new TypeError('Необработанная ошибка из console.js'); },
  rejectNow() { return Promise.reject(new Error('Необработанный reject')); },
};
setTimeout(() => consoleTest.throwNow(), 200);
setTimeout(() => consoleTest.rejectNow(), 300);
