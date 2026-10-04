const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
admin.initializeApp();

exports.notifyNewBook = onDocumentCreated("books/{bookId}", async (event) => {
    const snap = event.data;
    if (!snap) return;

    const newBook = snap.data();
    const author = newBook.author;
    const title = newBook.title;
    const newBookId = event.params.bookId;

    console.log(`Trigger attivato: Nuovo libro - ${title} di ${author}`);

    if (!author || author === "Sconosciuto") {
        console.log("Autore non profilabile, skip notifiche mirate.");
        return;
    }

    const booksSnapshot = await admin.firestore().collection("books")
        .where("author", "==", author).get();

    const authorBookIds = [];
    booksSnapshot.forEach(doc => authorBookIds.push(doc.id));

    if (authorBookIds.length <= 1) {
         console.log("Nuovo autore nel catalogo. Nessuno storico utente presente.");
         return;
    }

    const usersSnapshot = await admin.firestore().collection("users")
        .orderBy("fcmToken").get();

    const tokensToSend = [];

    for (const userDoc of usersSnapshot.docs) {
        const userData = userDoc.data();
        if (!userData.fcmToken) continue;

        const progressSnapshot = await admin.firestore()
            .collection("users").doc(userDoc.id).collection("progress").get();

        let isFanOfAuthor = false;

        progressSnapshot.forEach(progDoc => {
            if (authorBookIds.includes(progDoc.id) && progDoc.id !== newBookId) {
                isFanOfAuthor = true;
            }
        });

        if (isFanOfAuthor) {
            tokensToSend.push(userData.fcmToken);
        }
    }

    if (tokensToSend.length > 0) {
        console.log(`Match trovati! Invio notifica a ${tokensToSend.length} dispositivi.`);

        const message = {
            notification: {
                title: "Nuovo Audiolibro Consigliato!",
                body: `È appena uscito "${title}" di ${author}. Dato che hai ascoltato altri suoi lavori, pensiamo ti piacerà!`,
            },
            tokens: tokensToSend
        };

        const response = await admin.messaging().sendEachForMulticast(message);
        console.log(`Notifiche inviate con successo: ${response.successCount}`);
    } else {
        console.log("Nessun utente compatibile trovato.");
    }
});